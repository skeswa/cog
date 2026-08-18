/// The container for one Cog state graph.
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
/// refreshing, registering reactions, or committing operations.
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

  /// One test-only acknowledgement installed through the CogTesting product.
  private var nextLifetimeReleaseAcknowledgement: (@MainActor @Sendable () -> Void)?

  /// Signals after the next grace-expiry release check, including a pinned skip.
  private var nextLifetimeReleaseCheckAcknowledgement: (@MainActor @Sendable () -> Void)?

  /// One test-only signal after an async result reaches its commit eligibility check.
  ///
  /// Cancellation and ignored-cancellation scenarios need to prove that a
  /// result was rejected, which produces no public status event to await. The
  /// `CogTesting` seam installs this callback as a deterministic negative-event
  /// acknowledgement. Production code never installs one.
  private var nextAsyncCompletionCheckAcknowledgement: (@MainActor @Sendable () -> Void)?

  /// The monotonic version assigned to graph work.
  ///
  /// Each outer turn advances it once, including an empty or all-equal turn. A
  /// changed debug seed also advances it.
  internal private(set) var revision: CogVersion = .initial

  #if COG_CORE_ARENA
  /// Data-oriented graph selected for this build-time arena test leg.
  ///
  /// Public references remain unchanged; manual, synchronous derived, async,
  /// reaction, lifetime, Observation, and history paths share its scalar rows.
  internal let arenaCore: CogArenaCore
  #endif

  /// One enter/exit buffer reused by iterative settle walks.
  internal var settleStack = CogSettleStack()

  /// How many settle walks are active, counting the outermost.
  ///
  /// Only cold first reads nest walks, and each nested walk costs real Swift
  /// stack. `Cogs.maximumSettleDepth` bounds this so the failure is a
  /// diagnosis rather than a stack smash (GRAPH-14).
  internal var settleDepth = 0

  /// The structural phase of the current turn, or idle between turns.
  ///
  /// This begins as the small correctness representation from §3.2. The
  /// data-oriented core later replaces it without exposing the phase as API.
  internal var turnPhase: CogTurnPhase = .idle

  /// Turns that cannot safely run yet, in arrival order.
  ///
  /// Application commits enqueue while a turn is flushing. Runtime-owned async
  /// turns also enqueue while a selector or reaction is tracking even when the
  /// context is otherwise idle. The current outer turn or the first safe graph
  /// boundary drains this FIFO only after mutation and value evaluation finish,
  /// preventing nested Observation or reaction propagation.
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
  ///
  /// Swift Observation has no exact removal signal that Cog can rely on, so the
  /// first boundary is context-lifetime in v1. Cancelling the state's owned
  /// grace sleeper before registration prevents a transient-demand deadline
  /// from releasing state after the UI has made it durable.
  internal func registerObservationState(_ state: any CogObservationState) {
    if let lifetimeState = state as? any CogLifetimeLeaseState {
      lifetimeState.cancelPendingLifetimeRelease()
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

  #if COG_CORE_SIMPLE
  /// What this context has done lately (§2.3, perf §8).
  ///
  /// The arena core owns its integer recorder instead. Both histories and all
  /// recording call sites compile out of release builds (`HIST-04`).
  internal var historyLog = CogHistoryLog()
  #endif
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
  package init(
    clock: any Clock<Duration> = ContinuousClock(),
    defaultWhileObservedGrace: Duration = .seconds(30)
  ) {
    self.clock = clock
    self.defaultWhileObservedGrace = defaultWhileObservedGrace
    #if COG_CORE_ARENA
    self.arenaCore = CogArenaCore()
    #endif
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

  /// Breaks graph-owned dependency chains before stored properties release.
  ///
  /// Mechanism scopes cancel first — unregistering reactions, requesting task
  /// cancellation, and releasing controllers — and the retained mechanism
  /// values are released only afterward, so a class-owned resource outlives
  /// its last registration (§6.2). Strong dependency chains can make ARC
  /// recurse during teardown, so a flat pass then breaks them before stored
  /// properties are released. Lifetime states prepare first so an async state
  /// cancels its task and invalidates that task's generation before the
  /// context releases the graph around it.
  isolated deinit {
    for scope in mechanismScopes {
      scope.cancel()
    }
    mechanismScopes.removeAll()
    mechanisms.removeAll()

    for state in states.values {
      (state as? any CogLifetimeLeaseState)?.prepareForLifetimeRelease()
      (state as? any CogConsumer)?.releaseDependenciesForContextTeardown()
    }
    for reaction in reactions {
      reaction.releaseDependenciesForContextTeardown()
    }
    #if COG_CORE_ARENA
    arenaCore.prepareForContextTeardown()
    #endif
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
  /// Adds one reaction-owned lease when this state uses observed lifetime.
  ///
  /// Advancing the release generation invalidates an earlier grace task.
  internal func acquireExternalLease(on state: any CogLifetimeLeaseState) {
    guard case .whileObserved = state.lifetime else { return }
    state.cancelPendingLifetimeRelease()
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
  /// A one-shot synchronous or async `peek`, or a cold async `refresh`, creates
  /// real demand but intentionally installs no reaction or UI consumer. This
  /// overload gives that state the same renewable grace as a state whose final
  /// durable lease disappeared. App-lifetime, reaction-leased, and UI-pinned
  /// states are no-ops; an internal subscriber can defer removal when the
  /// deadline arrives but does not count as observation or renew grace.
  internal func scheduleLifetimeReleaseIfUnobserved(_ state: any CogLifetimeLeaseState) {
    guard case .whileObserved(let declaredGrace) = state.lifetime else { return }
    scheduleLifetimeReleaseIfUnobserved(state, declaredGrace: declaredGrace)
  }

  /// Schedules one renewable release deadline using the resolved grace.
  ///
  /// Each state owns at most one sleeper. Renewal cancels and replaces that
  /// task, while a generation check still rejects a completion that raced with
  /// cancellation. The task captures both context and state weakly, so the
  /// deadline itself cannot extend either lifetime.
  ///
  /// `pendingLifetimeReleaseGeneration` distinguishes a future deadline from
  /// one that elapsed while an internal subscriber still needed the state; the
  /// release cascade uses that distinction to avoid granting a second grace
  /// window.
  private func scheduleLifetimeReleaseIfUnobserved(
    _ state: any CogLifetimeLeaseState,
    declaredGrace: Duration?
  ) {
    guard state.externalLeaseCount == 0 else { return }
    guard (state as? any CogObservationState)?.observationBoundary == nil else { return }

    state.lifetimeReleaseTask?.cancel()
    let generation = state.advanceLifetimeReleaseGeneration()
    state.pendingLifetimeReleaseGeneration = generation
    let identity = state.stateIdentity
    let grace = declaredGrace ?? defaultWhileObservedGrace
    let clock = clock

    state.lifetimeReleaseTask = Task { @MainActor [weak self, weak state] in
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

  /// Installs a one-shot acknowledgement for the next successful state release.
  ///
  /// Pinned or otherwise ineligible expiry checks do not consume this callback;
  /// use ``acknowledgeNextDerivedReleaseCheck(_:)`` when the check itself is the
  /// event under test.
  ///
  /// - Parameter acknowledgement: MainActor callback consumed after the next
  ///   eligible derived-state closure is removed.
  package func acknowledgeNextDerivedRelease(
    _ acknowledgement: @escaping @MainActor @Sendable () -> Void
  ) {
    guard nextLifetimeReleaseAcknowledgement == nil else {
      fatalError("CogTesting installed two acknowledgements for the next derived release.")
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
  package func acknowledgeNextDerivedReleaseCheck(
    _ acknowledgement: @escaping @MainActor @Sendable () -> Void
  ) {
    guard nextLifetimeReleaseCheckAcknowledgement == nil else {
      fatalError("CogTesting installed two acknowledgements for the next release check.")
    }
    nextLifetimeReleaseCheckAcknowledgement = acknowledgement
  }

  /// Consumes the package-only signal after one grace check completes.
  ///
  /// Both storage cores share this context-owned testing seam; the callback
  /// never enters arena storage or changes release eligibility.
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
    #if COG_CORE_ARENA
    arenaCore.observationBoundaryCount
    #else
    observationStates.count
    #endif
  }

  /// Whether this source's exact state currently owns an Observation boundary.
  ///
  /// Purely a lookup: a state never demanded in this context reports `false`
  /// without being created, so probing cannot disturb laziness or lifetime.
  package func hasObservationBoundaryForTesting<Value>(
    for valueReference: ManualCog<Value>
  ) -> Bool {
    hasObservationBoundary(
      CogStateIdentity(descriptor: valueReference.descriptor.identity, key: valueReference.key))
  }

  /// Whether this derived cog's exact state currently owns an Observation
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
    #if COG_CORE_ARENA
    arenaCore.hasObservationBoundary(for: identity)
    #else
    (states[identity] as? any CogObservationState)?.observationBoundary != nil
    #endif
  }

  #if COG_CORE_ARENA
  /// Exercises derived-state release and replacement through the arena core.
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
  #endif

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
    defer { acknowledgeLifetimeReleaseCheckIfRequested() }

    if state.pendingLifetimeReleaseGeneration == generation {
      state.pendingLifetimeReleaseGeneration = nil
      state.lifetimeReleaseTask = nil
    }

    guard let stored = states[identity], stored === state else { return }
    guard state.lifetimeReleaseGeneration == generation else { return }
    guard state.externalLeaseCount == 0 else { return }
    guard case .whileObserved = state.lifetime else { return }
    guard (state as? any CogObservationState)?.observationBoundary == nil else { return }

    guard state.subscribers.isEmpty else { return }

    releaseUnobservedClosure(startingAt: state)

    acknowledgeLifetimeReleaseIfRequested()
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
    #if COG_CORE_ARENA
    arenaCore.advanceRevision()
    #endif
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

  #if COG_CORE_SIMPLE
  /// Resolves an async value reference to its simple-core state in this context.
  ///
  /// Lookup and work start are deliberately separate. Merely resolving the
  /// descriptor-and-key slot allocates state but does not run the selector;
  /// settlement by a tracked read, peek, or refresh creates the first pending
  /// status and starts work.
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

  /// Resolves the async state named by an internal value projection.
  ///
  /// The projection captures the original async descriptor and forwards its
  /// own key here. Reusing that descriptor-and-key identity makes
  /// the value projection observes the same status state as the full async
  /// value instead of creating a mirror or a second task.
  internal func asyncState<Value>(
    descriptor: AsyncCogDescriptor<Value>,
    key: CogKey?
  ) -> AsyncCogState<Value> {
    state(CogStateIdentity(descriptor: descriptor.identity, key: key)) {
      AsyncCogState(descriptor: descriptor, key: key)
    }
  }
  #endif

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
  public func peek<Value>(_ valueReference: ManualCog<Value>) -> Value {
    #if COG_CORE_ARENA
    let value = arenaCore.manualValue(for: valueReference)
    arenaCore.scheduleLifetimeReleaseIfUnobserved(for: valueReference, in: self)
    return value
    #else
    let state = manualState(for: valueReference)
    // An `.app` source ignores this. An ephemeral one treats a one-shot read as
    // the transient demand it is: real enough to renew grace, not durable
    // enough to keep the value alive on its own.
    scheduleLifetimeReleaseIfUnobserved(state)
    return state.currentValue
    #endif
  }

  /// Reads a derived cog's value without creating a dependency edge.
  ///
  /// The call computes the cog if needed and settles stale dependencies before
  /// returning, so non-tracking never means stale. It neither registers an
  /// Observation boundary nor attaches the caller as a graph consumer. For a
  /// default `whileObserved` cog, this transient demand starts or renews ordinary
  /// grace; repeated peeks share one state and one owned grace sleeper, while
  /// expiry releases the unobserved state. Inside a selector or reaction, use
  /// that reader's subscript when future changes must rerun the body.
  ///
  /// - Parameter valueReference: The derived cog to read.
  /// - Returns: Its fully settled value in this context.
  public func peek<Value>(_ valueReference: Cog<Value>) -> Value {
    #if COG_CORE_ARENA
    let value = arenaCore.derivedValue(for: valueReference, in: self)
    arenaCore.scheduleLifetimeReleaseIfUnobserved(for: valueReference, in: self)
    return value
    #else
    let state = derivedState(for: valueReference)
    let value = state.settledValue(in: self)
    scheduleLifetimeReleaseIfUnobserved(state)
    return value
    #endif
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
  public func peek<Value>(_ valueReference: AsyncCog<Value>) -> Value {
    peek(valueReference.valueCog)
  }
}
