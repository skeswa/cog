/// The MainActor-confined runtime for one Cog state graph.
///
/// A context creates state when a declaration is first read, refreshed, or
/// written. A declaration and optional box key name one state. Copies point to
/// that state within one context, while each context stays isolated. An app has
/// one context; each test or preview can have its own.
///
/// Reads settle every dependency needed for the answer. App writes and async
/// status changes publish as ordered turns. Notifications and reactions wait
/// until the active computation ends. UI reads use Swift Observation, tracked
/// readers record graph edges, and `peek` does neither.
///
/// `Cogs` and all graph access are MainActor-isolated. It is not a container
/// to pass between arbitrary executors: enter the MainActor before reading,
/// refreshing, registering reactions, or publishing operations.
///
/// Call ``assemble(mechanisms:)`` once when an app launches. Tests and previews use
/// `Cogs.forTesting()` from the `CogTesting` product.
@MainActor
public final class Cogs {
  /// The mechanisms this runtime operates, in assembly list order.
  ///
  /// The runtime retains the exact mechanism values supplied at assembly so
  /// a class-owned resource cannot disappear while one of its reactions or
  /// tasks is still registered. Teardown cancels every scope first and
  /// releases these values only afterward.
  private var mechanisms: [any Mechanism] = []

  /// Each assembly mechanism's registration scope, parallel to `mechanisms`.
  ///
  /// A scope owns its mechanism's reactions, tasks, open `whenever` children,
  /// and controller. Nothing else may register effects: the public `Cogs`
  /// surface deliberately has no reaction, watch, or effect-group API (§6.3).
  private var mechanismScopes: [MechanismScope] = []

  /// At most one test-installed acknowledgement per runtime event.
  ///
  /// These events let tests await decisions that publish no status, value, or
  /// history entry. Each ``CogRuntimeEvent`` case defines its decision. Only
  /// `CogTesting` installs a callback through ``acknowledgeNext(_:with:)``.
  /// ``acknowledge(_:)`` consumes it after one firing, and teardown drops any
  /// callback still stored.
  private var runtimeAcknowledgements = CogRuntimeAcknowledgements()

  /// The monotonic clock used by context-owned timing work.
  ///
  /// Production uses ``ContinuousClock``. `CogTesting` can supply a controlled
  /// clock for deterministic waits.
  internal let clock: any Clock<Duration>

  /// Grace used when a descriptor selects the context default.
  internal let defaultWhileObservedGrace: Duration

  /// Observation implementation selected for this context.
  ///
  /// Production is always automatic. `CogTesting` can force the legacy path on
  /// a newer host without changing another isolated context or global state.
  internal let externalObservationTrackingMode: CogExternalObservationTrackingMode

  /// The data-oriented graph owned by this context.
  ///
  /// Public references remain unchanged; manual, synchronous automatic, async,
  /// reaction, lifetime, Observation, and history paths share its scalar rows.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  internal let arenaCore: CogArenaCore

  /// How many settle walks are active, counting the outermost.
  ///
  /// Only cold first reads nest walks, and each nested walk costs real Swift
  /// stack. `Cogs.maximumSettleDepth` bounds this so the failure is a
  /// diagnosis rather than a stack smash (GRAPH-14).
  internal var settleDepth = 0

  /// The structural phase of the current turn, or idle between turns.
  ///
  /// The context owns this coordination state because it orders public turn
  /// boundaries; arena rows hold graph data, not the boundary currently open.
  internal var turnPhase: CogTurnPhase = .idle

  /// Turns that cannot safely run yet, in arrival order.
  ///
  /// Application turns enqueue while a turn is flushing. Runtime-owned async
  /// turns also enqueue while a selector or reaction is tracking even when the
  /// context is otherwise idle. The current outer turn or the first safe graph
  /// boundary drains this FIFO only after mutation and value evaluation finish,
  /// preventing nested Observation or reaction propagation.
  internal var queuedTurns: [QueuedCogTurn] = []

  /// The one turn object this context reuses, rebound at the start of each turn.
  ///
  /// Turns never overlap, so one object suffices, and reusing it keeps the
  /// staged-source buffers at the capacity they have already reached.
  internal let reusedTurn = CogTurn()

  /// The last turn token minted; the next turn takes its successor.
  ///
  /// Monotonic and never reused, which is what makes a token unforgeable and
  /// an escaped writer's token stale. Wraparound would let an ancient writer
  /// look current, so it traps.
  internal var nextTurnToken: UInt64 = 0 {
    didSet {
      guard nextTurnToken != 0 else {
        fatalError("Cog exhausted its turn token counter.")
      }
    }
  }

  /// Tracked export terminals this context owns, in registration order.
  ///
  /// Keeping exports separate lets an effect-only flush scan each effect once
  /// while exports keep their earlier phase.
  internal var exportReactions: [CogReaction] = []

  /// Tracked effect terminals this context owns, in registration order.
  ///
  /// Flushes scan this registration-ordered array and ask the arena whether
  /// each terminal was reached, preserving order without object-reference edges.
  internal var reactions: [CogReaction] = []

  /// Work still to run in the active flush's export and effect phases.
  ///
  /// Changed exports run before effects. Registrations made during the flush
  /// append their initial run and finish before queued write-back turns.
  internal var reactionRuns: [CogReactionRun] = []

  /// External observable properties linked into this context, by exact identity.
  ///
  /// Each type-erased bridge owns one runtime-appropriate observer and one
  /// hidden source. Context ownership keeps the link singular across selector
  /// reruns and lets teardown cancel every observer before graph storage
  /// releases.
  internal var externalObservationBridges:
    [CogExternalObservationIdentity: any CogExternalObservationBridge] = [:]

  #if DEBUG
  /// How many graph operations currently make a quiet seed unsafe.
  ///
  /// This barrier also covers automatic equality checks and seed itself. It
  /// prevents a seed from being overwritten by the state mark that ends a run.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  internal var seedBarrierDepth = 0

  /// One synchronous root turn and the FIFO write-back turns it causes.
  ///
  /// The tracker warns once after a long chain and keeps its latest warning
  /// for `CogTesting`.
  internal var turnChainTracker = CogTurnChainTracker()

  #endif

  /// Creates an empty context.
  ///
  /// Package access limits construction to `assemble()` and the
  /// `CogTesting` factory. Construction is synchronous and MainActor-isolated;
  /// declarations remain inert until used with this context.
  ///
  /// - Parameters:
  ///   - clock: The monotonic clock for context-owned grace sleepers. Production
  ///     uses ``ContinuousClock``; tests inject a controllable clock.
  ///   - defaultWhileObservedGrace: Grace used by declarations that request
  ///     `whileObserved` without an explicit duration. Each state owns at most
  ///     one such sleeper, which later transient demand cancels and replaces.
  ///   - externalObservationTrackingMode: Runtime path for linked external
  ///     Observation state. Production uses automatic availability selection;
  ///     `CogTesting` may force the legacy path for compatibility proofs.
  package init(
    clock: any Clock<Duration> = ContinuousClock(),
    defaultWhileObservedGrace: Duration = .seconds(30),
    externalObservationTrackingMode: CogExternalObservationTrackingMode = .automatic
  ) {
    self.clock = clock
    self.defaultWhileObservedGrace = defaultWhileObservedGrace
    self.externalObservationTrackingMode = externalObservationTrackingMode
    self.arenaCore = CogArenaCore()
  }

  /// Installs a one-shot acknowledgement for one runtime event's next firing.
  ///
  /// The callback marks the decision named by the event, not merely a returned
  /// task. Each event allows one waiter so a test has one clear assertion.
  /// ``CogRuntimeEvent/deinitCleanup`` may be replaced because teardown fires
  /// only once. The caller must retain this context until the event fires;
  /// event paths capture it weakly, and teardown drops its callbacks.
  ///
  /// - Parameters:
  ///   - event: The runtime event whose next firing the test awaits.
  ///   - acknowledgement: MainActor callback consumed by that firing.
  package func acknowledgeNext(
    _ event: CogRuntimeEvent,
    with acknowledgement: @escaping @MainActor @Sendable () -> Void
  ) {
    if event != .deinitCleanup, runtimeAcknowledgements[event] != nil {
      fatalError(
        "CogTesting installed two acknowledgements for the next \(event.diagnosticName)."
      )
    }
    runtimeAcknowledgements[event] = acknowledgement
  }

  /// Consumes one runtime event's acknowledgement, when a test installed one.
  ///
  /// Firing paths call this after their eligibility decision, often from
  /// `defer`. Async paths first regain the weakly captured context. Accepted
  /// and rejected outcomes both unblock the waiter, while work that outlives
  /// the context cannot reach a callback the context no longer owns.
  internal func acknowledge(_ event: CogRuntimeEvent) {
    let acknowledgement = runtimeAcknowledgements[event]
    runtimeAcknowledgements[event] = nil
    acknowledgement?()
  }

  /// Cancels graph-owned work before stored properties release.
  ///
  /// Mechanism scopes cancel before retained mechanism values are released.
  /// This keeps a class-owned resource alive through its last registration
  /// (§6.2). Arena teardown then cancels async tasks, rejects their generations,
  /// and clears scalar topology without recursion.
  isolated deinit {
    for scope in mechanismScopes {
      scope.cancel()
    }
    mechanismScopes.removeAll()
    mechanisms.removeAll()

    for bridge in externalObservationBridges.values {
      bridge.cancel()
    }
    externalObservationBridges.removeAll()

    // Mechanism scopes removed their registrations above. The remaining
    // reactions are external value subscriptions. Clear their teardown leases,
    // then cancel them so waiting sequences finish and release their bodies.
    let remainingExports = exportReactions
    for reaction in remainingExports {
      reaction.releaseArenaLeasesForContextTeardown()
      reaction.cancel()
    }
    let remainingEffects = reactions
    for reaction in remainingEffects {
      reaction.releaseArenaLeasesForContextTeardown()
      reaction.cancel()
    }
    arenaCore.prepareForContextTeardown()
    acknowledge(.deinitCleanup)
  }
}

// MARK: - Mechanisms

extension Cogs {
  /// Operates the runtime's mechanisms, exactly once, in list order.
  ///
  /// Only `assemble(mechanisms:)` and the `CogTesting` factory call this; there
  /// is no later install API. Each mechanism gets its own scope and controller.
  /// `operate` runs in place, so all mechanisms and their writes are settled
  /// before the factory returns.
  ///
  /// Two mechanisms sharing a name fail fast in debug and release builds,
  /// because history attribution and task naming depend on the name being
  /// unambiguous.
  package func operateMechanisms(_ list: [any Mechanism]) {
    guard !list.isEmpty else { return }
    guard mechanisms.isEmpty else {
      // `fatalError`, not `preconditionFailure`: optimized builds drop
      // `preconditionFailure` messages.
      fatalError(
        """
        This context already operated its mechanisms. Mechanisms are \
        specified once, at assembly; there is no later installation step.
        """
      )
    }

    var seenNames: Set<String> = []
    for mechanism in list {
      let name = mechanism.name
      guard seenNames.insert(name).inserted else {
        fatalError(
          """
          Two mechanisms in one assembly list are both named "\(name)". \
          Mechanism names attribute debug history, task names, and \
          diagnostics, so each mechanism needs its own. Give one of them an \
          explicit `name`.
          """
        )
      }
    }

    for mechanism in list {
      let scope = MechanismScope()
      let controller = MechanismController(
        cogs: self, namePath: mechanism.name, scope: scope)
      scope.retain(controller: controller)
      mechanisms.append(mechanism)
      mechanismScopes.append(scope)
      mechanism.operate(controller)
    }
  }

}

// MARK: - State storage

extension Cogs {
  /// How many exact states a UI read has pinned with an Observation boundary.
  ///
  /// This `CogTesting` seam returns only a count, not states, storage, or
  /// boundary objects. UI-05 can measure the cost of view reads without
  /// depending on the state layout.
  package var observationBoundaryCountForTesting: Int {
    arenaCore.observationBoundaryCount
  }

  /// Whether this source's exact state currently owns an Observation boundary.
  ///
  /// Purely a lookup: a state never demanded in this context reports `false`
  /// without being created, so probing cannot disturb laziness or lifetime.
  package func hasObservationBoundaryForTesting<Value>(
    for valueReference: Cog<Value>.Manual
  ) -> Bool {
    hasObservationBoundary(
      CogStateIdentity(descriptor: valueReference.descriptor.identity, key: valueReference.key))
  }

  /// Whether this automatic cog's exact state currently owns an Observation
  /// boundary.
  ///
  /// Purely a lookup: a state never demanded in this context reports `false`
  /// without being created, so probing cannot disturb laziness or lifetime.
  package func hasObservationBoundaryForTesting<Value>(
    for valueReference: Cog<Value>
  ) -> Bool {
    hasObservationBoundary(
      CogStateIdentity(descriptor: valueReference.descriptor.identity, key: valueReference.key))
  }

  /// Shared identity lookup behind the boundary probes above.
  private func hasObservationBoundary(_ identity: CogStateIdentity) -> Bool {
    arenaCore.hasObservationBoundary(for: identity)
  }

  /// Exercises automatic-state release and replacement through the arena core.
  ///
  /// Package-only for `CogTesting`; normal clients never receive slot handles.
  /// Both declarations are settled through their real typed columns, and the
  /// returned snapshot contains identity-free allocator facts only.
  package func arenaSlotReuseForTesting<ReleasedValue, ReplacementValue>(
    releasing releasedReference: Cog<ReleasedValue>,
    replacingWith replacementReference: Cog<ReplacementValue>
  ) -> CogArenaSlotReuseSnapshot {
    arenaCore.slotReuseSnapshot(
      releasing: releasedReference,
      replacingWith: replacementReference,
      in: self
    )
  }

  /// Deliberately touches a released slot after its row has been reused.
  ///
  /// This exists solely for PERF-05's debug child process. Successful behavior
  /// is termination with the stale-generation message, never a normal return.
  package func trapOnStaleArenaSlotAccessForTesting<ReleasedValue, ReplacementValue>(
    releasing releasedReference: Cog<ReleasedValue>,
    replacingWith replacementReference: Cog<ReplacementValue>
  ) {
    arenaCore.trapOnStaleSlotAccess(
      releasing: releasedReference,
      replacingWith: replacementReference,
      in: self
    )
  }

  /// Advances the graph revision for one turn flush or changed debug seed.
  internal func advanceRevision() {
    arenaCore.advanceRevision()
  }
}

// MARK: - Reading

extension Cogs {
  /// Reads a source's current value without creating a dependency edge.
  ///
  /// The read uses the source value from the latest completed turn. It does not
  /// register Swift Observation access and does not cause a selector or reaction
  /// to rerun later. Use this outside tracked bodies when code needs the value
  /// once; inside one, call that reader's subscript to record an edge.
  ///
  /// - Parameter valueReference: The source to read.
  /// - Returns: The value the source holds in this context, which is its
  ///   declaration's starting value until a turn writes it.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  public func peek<Value>(_ valueReference: Cog<Value>.Manual) -> Value {
    arenaCore.manualValueForTransientDemand(for: valueReference, in: self)
  }

  /// Reads an automatic cog's value without creating a dependency edge.
  ///
  /// The call computes the cog if needed and settles stale dependencies before
  /// returning, so non-tracking never means stale. It neither registers an
  /// Observation boundary nor attaches the caller as a graph consumer. For a
  /// default `whileObserved` cog, this transient demand starts or renews ordinary
  /// grace; repeated peeks share one state and one owned grace sleeper, while
  /// expiry releases the unobserved state. Inside a selector or reaction, use
  /// that reader's subscript when future changes must rerun the body.
  ///
  /// - Parameter valueReference: The automatic cog to read.
  /// - Returns: Its fully settled value in this context.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  public func peek<Value>(_ valueReference: Cog<Value>) -> Value {
    arenaCore.automaticValueForTransientDemand(for: valueReference, in: self)
  }

  /// Reads an async cog's current value without creating a dependency edge.
  ///
  /// A first one-shot read starts the initial work and returns the
  /// declaration's resting default; afterward it returns the last accepted
  /// success. Because the read installs no durable consumer, it also starts
  /// the declaration's ordinary `whileObserved` grace. The state owns at most
  /// one grace sleeper; another one-shot read cancels and replaces it without
  /// replacing work already in flight. The returned value is fully settled at
  /// the latest completed turn, just like a tracked read; only future
  /// invalidation is intentionally omitted. No Swift Observation boundary or
  /// reaction lease is created. Use ``Cogs/status`` to peek the request
  /// lifecycle instead.
  ///
  /// - Parameter valueReference: The async declaration and optional key to inspect.
  /// - Returns: Its current settled value, resting on the default at first
  ///   demand.
  public func peek<Value>(_ valueReference: Cog<Value>.Async) -> Value {
    peek(valueReference.valueCog)
  }
}
