/// The container for one Cog state graph.
///
/// A context creates state lazily as declarations are read or written. One
/// running app uses one context; each test or preview may create its own.
///
/// Call ``bootstrapApp()`` once when an app launches. Tests and previews use
/// `Cogtext.forTesting()` from the `CogTesting` product. All graph operations
/// run on the MainActor.
@MainActor
public final class Cogtext {
  /// The monotonic clock used by context-owned timing work.
  ///
  /// Production uses ``ContinuousClock``. `CogTesting` can supply a controlled
  /// clock for deterministic waits.
  internal let clock: any Clock<Duration>

  /// Grace used when a descriptor selects the context default.
  internal let defaultWhileObservedGrace: Duration

  /// One test-only acknowledgement installed through the CogTesting product.
  private var nextLifetimeReleaseAcknowledgement: (@MainActor @Sendable () -> Void)?

  /// Signals after the next grace-expiry release check, including a pinned skip.
  private var nextLifetimeReleaseCheckAcknowledgement: (@MainActor @Sendable () -> Void)?

  /// One test-only signal after an async result reaches its generation check.
  private var nextAsyncCompletionCheckAcknowledgement: (@MainActor @Sendable () -> Void)?

  /// The monotonic version assigned to graph work.
  ///
  /// Each outer turn advances it once, including an empty or all-equal turn. A
  /// changed debug seed also advances it.
  internal private(set) var revision: CogVersion = .initial

  /// One enter/exit buffer reused by iterative settle walks.
  internal var settleStack = CogSettleStack()

  /// The structural phase of the current turn, or idle between turns.
  ///
  /// This begins as the small correctness representation from §3.2. The
  /// data-oriented core later replaces it without exposing the phase as API.
  internal var turnPhase: CogTurnPhase = .idle

  /// Commits requested while a turn is flushing, in arrival order.
  ///
  /// The outer `withTurn` drains this FIFO after its active turn returns to
  /// idle. New arrivals join the same queue.
  internal var queuedTurns: [QueuedCogTurn] = []

  /// Reactions this context owns, in registration order.
  ///
  /// The simple core scans this array after each flush and runs marked
  /// reactions. M6 replaces the scan with a measured flat queue without
  /// changing order or behavior.
  internal var reactions: [CogReaction] = []

  /// Work still to run in the active flush's reaction phase.
  ///
  /// Changed reactions run first. Registrations made during the flush append
  /// their initial run and finish before queued write-back turns.
  internal var reactionRuns: [CogReactionRun] = []

  /// Every state this context has been asked for, filed by descriptor and key.
  ///
  /// ``CogState`` erases each value type for storage. The value reference
  /// restores the concrete type at lookup.
  ///
  /// The correctness core uses a dictionary. The data-oriented core replaces
  /// it with slotted storage (perf §3), so lookups go through the methods below.
  internal private(set) var states: [CogStateIdentity: any CogState] = [:]

  /// States whose exact values have crossed the UI observation boundary.
  ///
  /// First UI reads append here in creation order. Flushes walk only these hot
  /// roots instead of scanning every interior state in the graph.
  internal private(set) var observationStates: [any CogObservationState] = []

  /// Pins one newly UI-read state in boundary creation order.
  internal func registerObservationState(_ state: any CogObservationState) {
    if let lifetimeState = state as? any CogLifetimeLeaseState {
      lifetimeState.advanceLifetimeReleaseGeneration()
    }
    observationStates.append(state)
  }

  /// Whose run is capturing dependencies right now, or `nil` between runs.
  ///
  /// Runs may nest but cannot interleave on the MainActor. ``tracking(_:_:)``
  /// saves and restores this slot around nested runs (§1.2, §2.4).
  internal var trackedConsumer: (any CogConsumer)?

  #if DEBUG
  /// How many graph operations currently make a quiet seed unsafe.
  ///
  /// This barrier also covers derived equality checks and seed itself. It
  /// prevents a seed from being overwritten by the state mark that ends a run.
  internal var seedBarrierDepth = 0

  /// One synchronous root turn and the FIFO write-back turns it causes.
  ///
  /// The tracker warns once after a long chain and keeps its latest warning
  /// for `CogTesting`.
  internal var turnChainTracker = CogTurnChainTracker()

  /// What this context has done lately (§2.3, perf §8).
  ///
  /// All history storage, types, and call sites compile out of release builds
  /// (`HIST-04`).
  internal var historyLog = CogHistoryLog()
  #endif

  /// Creates an empty context.
  ///
  /// Package access limits construction to `bootstrapApp()` and the
  /// `CogTesting` factory.
  package init(
    clock: any Clock<Duration> = ContinuousClock(),
    defaultWhileObservedGrace: Duration = .seconds(30)
  ) {
    self.clock = clock
    self.defaultWhileObservedGrace = defaultWhileObservedGrace
  }

  /// Installs a one-shot acknowledgement for the next async completion check.
  package func acknowledgeNextAsyncCompletionCheck(
    _ acknowledgement: @escaping @MainActor @Sendable () -> Void
  ) {
    guard nextAsyncCompletionCheckAcknowledgement == nil else {
      fatalError("CogTesting installed two acknowledgements for the next async completion check.")
    }
    nextAsyncCompletionCheckAcknowledgement = acknowledgement
  }

  /// Consumes the next async-completion acknowledgement, when a test installed one.
  internal func acknowledgeAsyncCompletionCheckIfRequested() {
    let acknowledgement = nextAsyncCompletionCheckAcknowledgement
    nextAsyncCompletionCheckAcknowledgement = nil
    acknowledgement?()
  }

  /// Breaks graph-owned dependency chains before stored properties release.
  ///
  /// Strong dependency chains can make ARC recurse during teardown. This flat
  /// pass breaks them before stored properties are released.
  isolated deinit {
    for state in states.values {
      (state as? any CogConsumer)?.releaseDependenciesForContextTeardown()
    }
    for reaction in reactions {
      reaction.releaseDependenciesForContextTeardown()
    }
  }
}

// MARK: - State storage

extension Cogtext {
  /// Adds one reaction-owned lease when this state uses observed lifetime.
  ///
  /// Advancing the release generation invalidates an earlier grace task.
  internal func acquireExternalLease(on state: any CogLifetimeLeaseState) {
    guard case .whileObserved = state.lifetime else { return }
    state.advanceLifetimeReleaseGeneration()
    state.incrementExternalLeaseCount()
  }

  /// Removes one reaction-owned lease when this state uses observed lifetime.
  ///
  /// Context teardown bypasses this path to avoid scheduling grace work.
  internal func releaseExternalLease(on state: any CogLifetimeLeaseState) {
    guard case .whileObserved(let declaredGrace) = state.lifetime else { return }
    state.decrementExternalLeaseCount()
    guard state.externalLeaseCount == 0 else { return }
    guard (state as? any CogObservationState)?.observationBoundary == nil else { return }

    let generation = state.advanceLifetimeReleaseGeneration()
    let identity = state.stateIdentity
    let grace = declaredGrace ?? defaultWhileObservedGrace
    let clock = clock

    Task { @MainActor [weak self, weak state] in
      do {
        try await clock.sleep(for: grace)
      } catch {
        return
      }

      guard let self, let state else { return }
      self.releaseDerivedStateIfEligible(
        state,
        identity: identity,
        generation: generation
      )
    }
  }

  /// Installs a one-shot behavior acknowledgement for a lifetime scenario.
  package func acknowledgeNextDerivedRelease(
    _ acknowledgement: @escaping @MainActor @Sendable () -> Void
  ) {
    guard nextLifetimeReleaseAcknowledgement == nil else {
      fatalError("CogTesting installed two acknowledgements for the next derived release.")
    }
    nextLifetimeReleaseAcknowledgement = acknowledgement
  }

  /// Installs a one-shot acknowledgement for the next grace-expiry check.
  package func acknowledgeNextDerivedReleaseCheck(
    _ acknowledgement: @escaping @MainActor @Sendable () -> Void
  ) {
    guard nextLifetimeReleaseCheckAcknowledgement == nil else {
      fatalError("CogTesting installed two acknowledgements for the next release check.")
    }
    nextLifetimeReleaseCheckAcknowledgement = acknowledgement
  }

  /// Removes the exact still-unobserved state after its grace task resumes.
  private func releaseDerivedStateIfEligible(
    _ state: any CogLifetimeLeaseState,
    identity: CogStateIdentity,
    generation: UInt64
  ) {
    let checkAcknowledgement = nextLifetimeReleaseCheckAcknowledgement
    nextLifetimeReleaseCheckAcknowledgement = nil
    defer { checkAcknowledgement?() }

    guard let stored = states[identity], stored === state else { return }
    guard state.lifetimeReleaseGeneration == generation else { return }
    guard state.externalLeaseCount == 0 else { return }
    guard case .whileObserved = state.lifetime else { return }
    guard (state as? any CogObservationState)?.observationBoundary == nil else { return }

    // A still-live internal consumer needs this exact producer until the later
    // closure-release slice can collect the whole unobserved dependency graph.
    guard state.subscribers.isEmpty else { return }

    states.removeValue(forKey: identity)
    state.releaseDependenciesForLifetime()

    let acknowledgement = nextLifetimeReleaseAcknowledgement
    nextLifetimeReleaseAcknowledgement = nil
    acknowledgement?()
  }

  /// Advances the graph revision for one turn flush or changed debug seed.
  @discardableResult
  internal func advanceRevision() -> CogVersion {
    revision = revision.advanced()
    return revision
  }

  /// Gets this source's state, creating it on first use in this context.
  ///
  /// The descriptor and key form the storage identity. For example,
  /// `box[90210]` and `box[10001]` resolve to separate states.
  internal func manualState<Value>(for valueReference: ManualCog<Value>) -> ManualCogState<Value> {
    state(CogStateIdentity(descriptor: valueReference.descriptor.identity, key: valueReference.key))
    {
      ManualCogState(descriptor: valueReference.descriptor, key: valueReference.key)
    }
  }

  /// Gets this derived state, creating it on first use in this context.
  ///
  /// Creation does not run the selector. The first read does (§2.2).
  internal func derivedState<Value>(for valueReference: Cog<Value>) -> DerivedCogState<Value> {
    state(CogStateIdentity(descriptor: valueReference.descriptor.identity, key: valueReference.key))
    {
      DerivedCogState(descriptor: valueReference.descriptor, key: valueReference.key)
    }
  }

  /// Gets this async state, creating it without starting work on first use.
  internal func asyncState<Value>(for valueReference: AsyncCog<Value>) -> AsyncCogState<Value> {
    asyncState(descriptor: valueReference.descriptor, key: valueReference.key)
  }

  /// Gets async state from a descriptor captured by its latest-value projection.
  internal func asyncState<Value>(
    descriptor: AsyncCogDescriptor<Value>,
    key: AnyHashable?
  ) -> AsyncCogState<Value> {
    state(CogStateIdentity(descriptor: descriptor.identity, key: key)) {
      AsyncCogState(descriptor: descriptor, key: key)
    }
  }

  /// Gets the state for `identity`, or files the result of `create`.
  ///
  /// Each descriptor identity maps to one concrete state type. Keep the cast
  /// check because a future storage implementation could break that invariant.
  private func state<State: CogState>(
    _ identity: CogStateIdentity,
    create: () -> State
  ) -> State {
    if let existing = states[identity] {
      guard let state = existing as? State else {
        // `fatalError`, not `preconditionFailure`: this message is composed,
        // and an optimized `preconditionFailure` drops composed messages, so
        // a release crash here would say nothing at all.
        fatalError(
          """
          The state for \(existing.label) is a \(type(of: existing)), not a \
          \(State.self). Two declarations cannot share one descriptor identity, \
          so this context's state storage is corrupt.
          """
        )
      }
      return state
    }

    let created = create()
    states[identity] = created
    return created
  }
}

// MARK: - Reading

extension Cogtext {
  /// Reads a source's current value without creating a dependency edge.
  ///
  /// Use this outside selectors when code needs the value once. Inside a
  /// selector, use ``Reader/subscript(_:)`` so changes can rerun the selector.
  ///
  /// - Parameter valueReference: The source to read.
  /// - Returns: The value the source holds in this context, which is its
  ///   declaration's starting value until a turn writes it.
  public func peek<Value>(_ valueReference: ManualCog<Value>) -> Value {
    manualState(for: valueReference).currentValue
  }

  /// Reads a derived cog's value without creating a dependency edge.
  ///
  /// The call computes the cog if needed and settles stale dependencies before
  /// returning. Inside a selector, use ``Reader/subscript(_:)`` so changes can rerun
  /// the selector.
  ///
  /// - Parameter valueReference: The derived cog to read.
  /// - Returns: Its value in this context.
  public func peek<Value>(_ valueReference: Cog<Value>) -> Value {
    derivedState(for: valueReference).settledValue(in: self)
  }

  /// Reads an async cog's current phase without creating a dependency edge.
  public func peek<Value>(_ valueReference: AsyncCog<Value>) -> CogPhase<Value> {
    asyncState(for: valueReference).settledPhase(in: self)
  }
}
