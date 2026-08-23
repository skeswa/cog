/// The MainActor-confined runtime for one Cog state graph.
///
/// A context creates state lazily as declarations are read, refreshed, or
/// written. Declaration identity plus an optional box key names one state slot,
/// so copied value references converge inside a context while separate contexts
/// remain isolated. One running app uses one context; each test or preview may
/// create its own.
///
/// Reads settle every dependency needed by the returned value. Application
/// writes and runtime-owned async status changes publish as ordered turns;
/// notifications and reactions run only after the active value computation has
/// finished. UI subscripts participate in Swift Observation, selector and
/// reaction readers record graph edges, and `peek` deliberately does neither.
///
/// `Cogs` and all graph access are MainActor-isolated. It is not a container
/// to pass between arbitrary executors: enter the MainActor before reading,
/// refreshing, registering reactions, or publishing operations.
///
/// Call ``bootstrapApp(mechanisms:)`` once when an app launches. Tests and previews use
/// `Cogs.forTesting()` from the `CogTesting` product.
@MainActor
public final class Cogs {
  /// The mechanisms this runtime operates, in bootstrap list order.
  ///
  /// The runtime retains the exact mechanism values supplied at bootstrap so
  /// a class-owned resource cannot disappear while one of its reactions or
  /// tasks is still registered. Teardown cancels every scope first and
  /// releases these values only afterward.
  private var mechanisms: [any Mechanism] = []

  /// Each bootstrap mechanism's registration scope, parallel to `mechanisms`.
  ///
  /// A scope owns its mechanism's reactions, tasks, open `whenever` children,
  /// and controller. Nothing else may register effects: the public `Cogs`
  /// surface deliberately has no reaction, watch, or effect-group API (§6.3).
  private var mechanismScopes: [MechanismScope] = []

  /// One package-only deinit signal consumed by deterministic cleanup tests.
  ///
  /// Fired at the end of `isolated deinit`, after mechanism scopes have been
  /// cancelled and graph dependency chains broken, so a test that dropped its
  /// last context reference off the MainActor can await actor-correct
  /// teardown instead of polling.
  private var deinitCleanupAcknowledgement: (@MainActor @Sendable () -> Void)?

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

  /// One test-only acknowledgement installed through the CogTesting product.
  private var nextLifetimeReleaseAcknowledgement: (@MainActor @Sendable () -> Void)?

  /// Signals after the next grace-expiry release check, including a pinned skip.
  private var nextLifetimeReleaseCheckAcknowledgement: (@MainActor @Sendable () -> Void)?

  /// One test-only signal after an async result reaches its turn eligibility check.
  ///
  /// Cancellation and ignored-cancellation scenarios need to prove that a
  /// result was rejected, which produces no public status event to await. The
  /// `CogTesting` seam installs this callback as a deterministic negative-event
  /// acknowledgement. Production code never installs one.
  private var nextAsyncCompletionCheckAcknowledgement: (@MainActor @Sendable () -> Void)?

  /// One test-only signal after the legacy external observer re-arms.
  ///
  /// The legacy bridge consumes this callback after installing its next
  /// one-shot registration and publishing the post-setter value. Production
  /// never installs one.
  private var nextExternalObservationRearmAcknowledgement: (@MainActor @Sendable () -> Void)?

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
  /// Keeping the phase physically separate makes the common effect-only flush
  /// scan each effect once while still giving exports their earlier phase.
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
  /// Package access limits construction to `bootstrapApp()` and the
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

  /// Installs a one-shot acknowledgement for the next async completion check.
  ///
  /// The callback runs after a work result has been accepted or rejected by
  /// the generation and state-identity checks. It therefore acknowledges a
  /// completed decision, not merely that the work closure returned. Only one
  /// waiter is supported because the seam exists for one deterministic test
  /// assertion at a time. The caller must retain this context until the result
  /// returns: the work task captures it weakly, and context teardown releases
  /// this stored callback together with the graph.
  ///
  /// - Parameter acknowledgement: MainActor callback consumed after the next
  ///   accepted or rejected completion reaches its eligibility decision.
  package func acknowledgeNextAsyncCompletionCheck(
    _ acknowledgement: @escaping @MainActor @Sendable () -> Void
  ) {
    guard nextAsyncCompletionCheckAcknowledgement == nil else {
      fatalError("CogTesting installed two acknowledgements for the next async completion check.")
    }
    nextAsyncCompletionCheckAcknowledgement = acknowledgement
  }

  /// Consumes the next async-completion acknowledgement, when a test installed one.
  ///
  /// Async completion paths call this from `defer` after obtaining the weakly
  /// captured context, so stale, cancelled, state-released, and accepted results
  /// all unblock the waiter after their eligibility check has finished. A
  /// result that outlives the context cannot reach this method or acknowledge a
  /// callback the context no longer owns.
  internal func acknowledgeAsyncCompletionCheckIfRequested() {
    let acknowledgement = nextAsyncCompletionCheckAcknowledgement
    nextAsyncCompletionCheckAcknowledgement = nil
    acknowledgement?()
  }

  /// Installs a one-shot signal for the next legacy Observation re-arm.
  ///
  /// Only compatibility tests use this package seam. The caller installs it
  /// after the initial tracked read and before the mutation whose completed
  /// transition it needs to await.
  ///
  /// - Parameter acknowledgement: MainActor callback consumed after the next
  ///   post-change one-shot registration is installed and its value published.
  package func acknowledgeNextExternalObservationRearm(
    _ acknowledgement: @escaping @MainActor @Sendable () -> Void
  ) {
    guard nextExternalObservationRearmAcknowledgement == nil else {
      fatalError("CogTesting installed two acknowledgements for the next Observation re-arm.")
    }
    nextExternalObservationRearmAcknowledgement = acknowledgement
  }

  /// Consumes the next legacy re-arm acknowledgement, when one is installed.
  internal func acknowledgeExternalObservationRearmIfRequested() {
    let acknowledgement = nextExternalObservationRearmAcknowledgement
    nextExternalObservationRearmAcknowledgement = nil
    acknowledgement?()
  }

  /// Cancels graph-owned work before stored properties release.
  ///
  /// Mechanism scopes cancel first — unregistering reactions, requesting task
  /// cancellation, and releasing controllers — and the retained mechanism
  /// values are released only afterward, so a class-owned resource outlives
  /// its last registration (§6.2). Arena teardown then cancels async tasks,
  /// invalidates their generations, and clears scalar topology iteratively.
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

    // Mechanism scopes removed their registrations above. Any survivors are
    // externally owned value subscriptions: clear their raw teardown leases,
    // then cancel them so their waiting AsyncSequences finish instead of
    // retaining inert reaction bodies after the graph is gone.
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
    deinitCleanupAcknowledgement?()
  }
}

// MARK: - Mechanisms

extension Cogs {
  /// Operates the runtime's mechanisms, exactly once, in list order.
  ///
  /// Only `bootstrapApp(mechanisms:)` and the `CogTesting` factory call this,
  /// which is what makes registration bootstrap-only: there is no later
  /// installation API. Each mechanism receives its own scope and curated
  /// controller; `operate` runs synchronously, so every mechanism is live —
  /// and its operate-time writes settled — before the factory returns.
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
        specified once, at bootstrap; there is no later installation step.
        """
      )
    }

    var seenNames: Set<String> = []
    for mechanism in list {
      let name = mechanism.name
      guard seenNames.insert(name).inserted else {
        fatalError(
          """
          Two mechanisms in one bootstrap list are both named "\(name)". \
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

  /// Installs the package-only signal emitted after isolated deinit cleanup.
  ///
  /// `CogTesting` uses this acknowledgement instead of sleeping or polling
  /// graph storage when a test drops its last context reference on another
  /// executor. Production clients cannot install the hook.
  ///
  /// - Parameter body: The MainActor callback invoked after teardown
  ///   finishes.
  package func acknowledgeDeinitCleanup(
    with body: @escaping @MainActor @Sendable () -> Void
  ) {
    deinitCleanupAcknowledgement = body
  }
}

// MARK: - State storage

extension Cogs {
  /// Installs a one-shot acknowledgement for the next successful state release.
  ///
  /// Pinned or otherwise ineligible expiry checks do not consume this callback;
  /// use ``acknowledgeNextAutomaticReleaseCheck(_:)`` when the check itself is the
  /// event under test.
  ///
  /// - Parameter acknowledgement: MainActor callback consumed after the next
  ///   eligible automatic-state closure is removed.
  package func acknowledgeNextAutomaticRelease(
    _ acknowledgement: @escaping @MainActor @Sendable () -> Void
  ) {
    guard nextLifetimeReleaseAcknowledgement == nil else {
      fatalError("CogTesting installed two acknowledgements for the next automatic release.")
    }
    nextLifetimeReleaseAcknowledgement = acknowledgement
  }

  /// Installs a one-shot acknowledgement for the next grace-expiry check.
  ///
  /// The callback runs after the owned sleeper's identity, generation, lease,
  /// boundary, and subscriber checks, whether or not they permit removal.
  ///
  /// - Parameter acknowledgement: MainActor callback consumed after the next
  ///   grace-expiry eligibility check finishes.
  package func acknowledgeNextAutomaticReleaseCheck(
    _ acknowledgement: @escaping @MainActor @Sendable () -> Void
  ) {
    guard nextLifetimeReleaseCheckAcknowledgement == nil else {
      fatalError("CogTesting installed two acknowledgements for the next release check.")
    }
    nextLifetimeReleaseCheckAcknowledgement = acknowledgement
  }

  /// Consumes the package-only signal after one grace check completes.
  ///
  /// The callback remains context-owned: it never enters arena storage or
  /// changes release eligibility.
  internal func acknowledgeLifetimeReleaseCheckIfRequested() {
    let acknowledgement = nextLifetimeReleaseCheckAcknowledgement
    nextLifetimeReleaseCheckAcknowledgement = nil
    acknowledgement?()
  }

  /// Consumes the package-only signal after one state closure is released.
  internal func acknowledgeLifetimeReleaseIfRequested() {
    let acknowledgement = nextLifetimeReleaseAcknowledgement
    nextLifetimeReleaseAcknowledgement = nil
    acknowledgement?()
  }

  /// How many exact states a UI read has pinned with an Observation boundary.
  ///
  /// A diagnostic seam for `CogTesting`, not UI API. It reports only the count
  /// of boundary-pinned states — never the states, their storage, or the
  /// boundary objects — so behavior tests (UI-05) can hold "only what a view
  /// read pays for a boundary" without coupling to state representation.
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
    let value = arenaCore.manualValue(for: valueReference)
    arenaCore.scheduleLifetimeReleaseIfUnobserved(for: valueReference, in: self)
    return value
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
    let value = arenaCore.automaticValue(for: valueReference, in: self)
    arenaCore.scheduleLifetimeReleaseIfUnobserved(for: valueReference, in: self)
    return value
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
