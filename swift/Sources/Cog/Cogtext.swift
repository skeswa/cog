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

  /// One test-only signal after an async result reaches its commit eligibility check.
  ///
  /// Cancellation and ignored-cancellation scenarios need to prove that a
  /// result was rejected, which produces no public phase event to await. The
  /// `CogTesting` seam installs this callback as a deterministic negative-event
  /// acknowledgement. Production code never installs one.
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
  ///
  /// The callback runs after a work result has been accepted or rejected by
  /// the generation and state-identity checks. It therefore acknowledges a
  /// completed decision, not merely that the work closure returned. Only one
  /// waiter is supported because the seam exists for one deterministic test
  /// assertion at a time.
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
  /// Async completion paths call this from `defer` after obtaining the
  /// context, so stale, cancelled, released, and accepted results all unblock
  /// the waiter after their eligibility check has finished.
  internal func acknowledgeAsyncCompletionCheckIfRequested() {
    let acknowledgement = nextAsyncCompletionCheckAcknowledgement
    nextAsyncCompletionCheckAcknowledgement = nil
    acknowledgement?()
  }

  /// Breaks graph-owned dependency chains before stored properties release.
  ///
  /// Strong dependency chains can make ARC recurse during teardown. This flat
  /// pass breaks them before stored properties are released. Lifetime states
  /// prepare first so an async state cancels its task and invalidates that
  /// task's generation before the context releases the graph around it.
  isolated deinit {
    for state in states.values {
      (state as? any CogLifetimeLeaseState)?.prepareForLifetimeRelease()
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

    scheduleLifetimeReleaseIfUnobserved(state, declaredGrace: declaredGrace)
  }

  /// Starts grace for a state that became demanded without acquiring a lease.
  ///
  /// A one-shot async `peek` or cold `refresh` creates real demand and starts
  /// work, but intentionally installs no reaction or UI consumer. This overload
  /// gives that state the same renewable grace as a state whose final durable
  /// lease disappeared. App-lifetime and still-observed states are no-ops.
  internal func scheduleLifetimeReleaseIfUnobserved(_ state: any CogLifetimeLeaseState) {
    guard case .whileObserved(let declaredGrace) = state.lifetime else { return }
    scheduleLifetimeReleaseIfUnobserved(state, declaredGrace: declaredGrace)
  }

  /// Schedules one renewable release deadline using the resolved grace.
  ///
  /// Advancing the lifetime generation invalidates every older sleeper without
  /// retaining a cancellation handle for each renewal. The task captures both
  /// context and state weakly, so the deadline itself cannot extend either
  /// lifetime. `pendingLifetimeReleaseGeneration` distinguishes a future
  /// deadline from one that elapsed while an internal subscriber still needed
  /// the state; the release cascade uses that distinction to avoid granting a
  /// second grace window.
  private func scheduleLifetimeReleaseIfUnobserved(
    _ state: any CogLifetimeLeaseState,
    declaredGrace: Duration?
  ) {
    guard state.externalLeaseCount == 0 else { return }
    guard (state as? any CogObservationState)?.observationBoundary == nil else { return }

    let generation = state.advanceLifetimeReleaseGeneration()
    state.pendingLifetimeReleaseGeneration = generation
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
  ///
  /// Both identity and generation matter. The descriptor-and-key slot may have
  /// been released and recreated while this sleeper was suspended, and a later
  /// demand may have renewed grace on the same state object. External leases,
  /// an Observation boundary, and internal subscribers each keep the state
  /// alive. Once the root remains eligible, its newly disconnected dependency
  /// closure can leave at this same deadline.
  private func releaseDerivedStateIfEligible(
    _ state: any CogLifetimeLeaseState,
    identity: CogStateIdentity,
    generation: UInt64
  ) {
    let checkAcknowledgement = nextLifetimeReleaseCheckAcknowledgement
    nextLifetimeReleaseCheckAcknowledgement = nil
    defer { checkAcknowledgement?() }

    if state.pendingLifetimeReleaseGeneration == generation {
      state.pendingLifetimeReleaseGeneration = nil
    }

    guard let stored = states[identity], stored === state else { return }
    guard state.lifetimeReleaseGeneration == generation else { return }
    guard state.externalLeaseCount == 0 else { return }
    guard case .whileObserved = state.lifetime else { return }
    guard (state as? any CogObservationState)?.observationBoundary == nil else { return }

    guard state.subscribers.isEmpty else { return }

    releaseUnobservedClosure(startingAt: state)

    let acknowledgement = nextLifetimeReleaseAcknowledgement
    nextLifetimeReleaseAcknowledgement = nil
    acknowledgement?()
  }

  /// Releases a newly disconnected unobserved dependency closure at the
  /// deadline that released its root.
  ///
  /// A dependency with a separately pending grace keeps that deadline. A
  /// dependency whose earlier deadline already elapsed while an internal
  /// subscriber retained it joins this cascade immediately, so removing the
  /// subscriber never starts a second full grace window. The walk is iterative
  /// because a long derived chain must not turn context cleanup into recursive
  /// ARC or graph traversal.
  ///
  /// Each state prepares before removal. For async state that means cancelling
  /// active work and advancing its generation, which makes a completion racing
  /// with release ineligible before the descriptor-and-key slot becomes free
  /// for a fresh state.
  private func releaseUnobservedClosure(startingAt root: any CogLifetimeLeaseState) {
    var candidates: [any CogLifetimeLeaseState] = [root]
    var index = 0

    while index < candidates.count {
      let state = candidates[index]
      index += 1

      guard let stored = states[state.stateIdentity], stored === state else { continue }
      guard state.externalLeaseCount == 0 else { continue }
      guard case .whileObserved = state.lifetime else { continue }
      guard (state as? any CogObservationState)?.observationBoundary == nil else { continue }
      guard state.subscribers.isEmpty else { continue }
      guard state === root || state.pendingLifetimeReleaseGeneration == nil else { continue }

      let dependencies = (state as? any DerivedCogSettleState)?.dependencies ?? []
      state.prepareForLifetimeRelease()
      states.removeValue(forKey: state.stateIdentity)
      state.releaseDependenciesForLifetime()

      for dependency in dependencies {
        guard let lifetimeState = dependency as? any CogLifetimeLeaseState else { continue }
        candidates.append(lifetimeState)
      }
    }
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

  /// Resolves an async value reference to its state in this context.
  ///
  /// Lookup and work start are deliberately separate. Merely resolving the
  /// descriptor-and-key slot allocates state but does not run the selector;
  /// settlement by a tracked read, peek, or refresh creates the first pending
  /// phase and starts work.
  internal func asyncState<Value>(for valueReference: AsyncCog<Value>) -> AsyncCogState<Value> {
    asyncState(descriptor: valueReference.descriptor, key: valueReference.key)
  }

  /// Whether this exact async state still owns its descriptor-and-key slot.
  ///
  /// A generation is meaningful only within one state object. Release can
  /// remove that object and a later read can create a replacement whose
  /// generation numbers begin again. Async completion therefore checks object
  /// identity in storage as well as its captured generation before publishing.
  internal func stillStoresAsyncState<Value>(_ state: AsyncCogState<Value>) -> Bool {
    states[state.stateIdentity] === state
  }

  /// Resolves the async state named by an internal latest-value projection.
  ///
  /// The projection captures the original async descriptor and forwards its
  /// own key here. Reusing that descriptor-and-key identity makes
  /// `valueReference.latest` observe the same phase state as the full async
  /// value instead of creating a mirror or a second task.
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
  ///
  /// A first one-shot read starts the initial work. Because the read installs
  /// no durable consumer, it also starts the declaration's ordinary
  /// `whileObserved` grace. Another one-shot read renews that grace without
  /// replacing work already in flight. The returned phase is fully settled at
  /// the latest completed turn, just like a tracked read; only future
  /// invalidation is intentionally omitted.
  ///
  /// - Parameter valueReference: The async declaration and optional key to inspect.
  /// - Returns: Its current full phase, beginning with pending on first demand.
  public func peek<Value>(_ valueReference: AsyncCog<Value>) -> CogPhase<Value> {
    let state = asyncState(for: valueReference)
    let phase = state.settledPhase(in: self)
    scheduleLifetimeReleaseIfUnobserved(state)
    return phase
  }
}
