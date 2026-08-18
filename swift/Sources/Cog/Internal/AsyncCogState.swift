#if COG_CORE_SIMPLE

/// One selected queue request waiting behind the active one-shot run.
///
/// Selection has already captured this request's dependencies and operation,
/// but neither pending publication nor operation execution occurs until the
/// request reaches the FIFO head. Its generation binds any refresh waiter to
/// this exact request without making later queued work supersede it.
private struct AsyncQueuedRun<Value> {
  /// Stable identity assigned when the selector accepted this request.
  let generation: UInt64

  /// Deferred one-shot operation captured from that selector run.
  let operation: @Sendable @isolated(any) () async throws -> sending Value
}

/// The live state behind one ``AsyncCog`` value reference in one context.
///
/// This is derived state with a split computation: the synchronous selector
/// captures graph dependencies, then its returned ``Work`` runs outside
/// dependency tracking. The state publishes pending, success, and failure as
/// separate system turns so readers and push consumers observe only completed
/// status transitions. Initial demand is the exception: it must install honest
/// pending baseline synchronously, then preserves ordering with a deferred named
/// turn once its computing path unwinds. The context is the sole owner of the
/// descriptor-and-key slot; work and grace tasks hold it weakly and must pass
/// identity plus generation checks before mutating MainActor-confined state.
internal final class AsyncCogState<Value>:
  CogState, CogConsumer, CogReaderState, DerivedCogSettleState, CogLifetimeLeaseState,
  CogObservationState, PendingCogSource
{
  /// The stable declaration shared by every copy of the value reference.
  let descriptor: AsyncCogDescriptor<Value>

  /// The keyed instance of `descriptor`, or `nil` for a keyless declaration.
  ///
  /// Together with descriptor object identity, this is stable for the full
  /// lifetime of the state and names its context storage slot and task.
  let key: CogKey?

  /// The declaration half of the context's descriptor-and-key storage identity.
  var descriptorIdentity: ObjectIdentifier { descriptor.identity }

  /// Whether settlement is currently running this state's synchronous selector.
  ///
  /// Mirrored in the context's computing path: the bit provides the common cycle
  /// check, while the ordered path produces diagnostics and balances nested runs.
  var isComputing = false

  /// Producers read by the latest synchronous selector run, in read order.
  ///
  /// Work-body reads cannot enter this list: tracking ends before ``Work``
  /// starts. A changed producer invalidates this state through its reverse edge,
  /// including while no durable consumer is present during lifetime grace.
  internal private(set) var dependencies: [any CogState] = []

  /// Fresh state is DIRTY so its first read selects and starts work.
  var settleState: CogSettleState = .dirty

  /// The revision of the last status publication visible to readers.
  ///
  /// The exceptional synchronous pending baseline uses the current revision and
  /// queues an empty named turn; it has no pre-existing consumers to invalidate.
  var changedAt: CogVersion = .initial

  /// The revision through which the selector and its dependencies are current.
  ///
  /// A queued reload marks the selector checked in the source turn without
  /// publishing pending early; its later system turn advances both timestamps.
  var checkedAt: CogVersion = .initial

  /// Weak reverse edges to status or projection consumers.
  var subscribers: [CogSubscriberEdge] = []

  /// Created only when this exact async status crosses the UI boundary.
  var observationBoundary: CogObservationBoundary?

  /// The erased key rendered with UI notices for this boundary.
  var observationKey: CogKey? { key }
  var label: CogLabel { descriptor.label }

  /// The declaration's lifetime policy, shared by every key of a box.
  var lifetime: CogStateLifetime { descriptor.lifetime }

  /// Exact reaction-owned leases currently keeping this state observed.
  var externalLeaseCount = 0

  /// Invalidates an earlier grace task whenever observation is renewed.
  var lifetimeReleaseGeneration: UInt64 = 0

  /// The generation whose scheduled grace deadline has not yet elapsed.
  ///
  /// Once the task for this generation wakes, it clears this marker before
  /// checking internal subscribers. That distinction lets an already-expired
  /// dependency join a later release cascade without receiving a second grace.
  var pendingLifetimeReleaseGeneration: UInt64? = nil

  /// The single cancellable task waiting for this state's current deadline.
  var lifetimeReleaseTask: Task<Void, Never>?

  /// The exact slot this context must still map to this object before accepting
  /// a task result or releasing state.
  ///
  /// State identity alone cannot reject recreation, so callers also compare the
  /// stored object by identity.
  var stateIdentity: CogStateIdentity {
    CogStateIdentity(descriptor: descriptorIdentity, key: key)
  }

  /// The status staged by a system turn but not yet published to readers.
  ///
  /// Like a manual source's pending value, this slot is consumed exactly once by
  /// ``flushPendingValue(in:at:)``. Keeping staging separate from `status` makes
  /// each async transition atomic with the rest of its named turn.
  private var pendingStatus: CogStatus<Value>?

  /// The status from the latest completed publication turn.
  ///
  /// Absence means this state has never settled. A successful settlement always
  /// gives the first caller an honest pending kind rather than exposing an
  /// initial lifecycle state.
  private var status: CogStatus<Value>?

  /// Status fields changed by this state's latest publication turn.
  ///
  /// Publication computes this set before replacing `status`. Observation
  /// flush consumes it later, after every affected graph root has settled, so
  /// each field mutation preserves the same turn ordering as ordinary values.
  private var observationChanges: CogStatusObservationFields = []

  /// The last accepted success, retained through pending and failure status.
  ///
  /// The outer optional preserves a successful optional `nil` distinctly from
  /// no accepted success.
  private var lastSuccess: Value?

  /// The cancellation handle for the currently executing generation.
  ///
  /// Latest replacement may detach an older task that ignores cancellation;
  /// queue policy instead keeps this handle unchanged until the head finishes.
  private var activeTask: Task<Void, Never>?

  /// The exact generation currently executing, independent of later queue IDs.
  ///
  /// `.latest` also records this value, but its newest generation remains the
  /// acceptance check. `.queue` needs the separate field because accepting
  /// later FIFO entries advances `generation` before the head completes.
  private var activeRunGeneration: UInt64?

  /// Selected `.queue` requests that have not published pending or started.
  private var queuedRuns: [AsyncQueuedRun<Value>] = []

  /// The monotonically increasing identity assigned to accepted work.
  ///
  /// Latest policy uses the newest ID as its acceptance boundary. Queue policy
  /// may have several larger IDs waiting while `activeRunGeneration` identifies
  /// the only request allowed to complete. Lifetime release advances the counter
  /// so no detached task can revive a removed state.
  private var generation: UInt64 = 0

  /// Awaitable explicit-refresh handles, filed by their exact generation.
  ///
  /// Ordinary read- or dependency-started generations need no cell. Starting
  /// replacement work resolves every older cell as superseded; lifetime
  /// release resolves the remaining cells as released.
  private var refreshWaiters: [UInt64: CogRefreshWaiter<Value>] = [:]

  /// The last completed status available to `Reader.curr`, preserving initial absence.
  var readerCurrentValue: CogStatus<Value>? { status }

  /// Creates an uncomputed, task-free state for one context storage identity.
  init(descriptor: AsyncCogDescriptor<Value>, key: CogKey?) {
    self.descriptor = descriptor
    self.key = key
  }

  /// Settles dependencies and starts work when needed, then returns the latest
  /// completed status publication.
  ///
  /// Both tracked and one-shot reads enter here. Therefore no read can bypass a
  /// dependency invalidation or observe state before initial pending exists.
  func settledStatus(in cogs: Cogs) -> CogStatus<Value> {
    if let cycle = cogs.settleStack.cyclePath(ifEntering: self) {
      fatalError(cycle.message)
    }

    if settleState != .clean {
      cogs.settle(self)
    }

    guard let status else {
      fatalError("A settled async Cog lost its status.")
    }
    return status
  }

  /// Forces the selector and work to run again under the normal settle path.
  ///
  /// A never-settled refresh is the initial demand and must not immediately
  /// replace the work it just started. Later refreshes use a named pending
  /// system turn, recapture dependencies, and follow the same generation rules
  /// as dependency-triggered replacement.
  func refresh(in cogs: Cogs) -> CogRefresh<Value> {
    let waiter = CogRefreshWaiter<Value>()
    let refresh = CogRefresh(waiter: waiter)
    guard status != nil else {
      _ = settledStatus(in: cogs)
      register(waiter, for: generation)
      return refresh
    }

    cogs.withSystemTurn("\(renderedName) pending") { turn in
      if let cycle = cogs.settleStack.cyclePath(ifEntering: self) {
        fatalError(cycle.message)
      }
      cogs.settleStack.beginComputing(self)
      defer { cogs.settleStack.endComputing(self) }
      self.startWork(
        in: cogs,
        publishingPendingIn: turn,
        refreshWaiter: waiter
      )
    }
    return refresh
  }

  /// Records one synchronous selector read and installs its reverse invalidation edge.
  func recordDependency(on producer: any CogState) {
    dependencies.append(producer)
    producer.addSubscriber(self)
  }

  /// Breaks strong forward edges before whole-context ARC teardown.
  ///
  /// Reverse edges need no individual removal because the context is discarding
  /// every state. Clearing only the strong side first keeps deep graph teardown
  /// iterative rather than recursively releasing a dependency chain.
  func releaseDependenciesForContextTeardown() {
    dependencies.removeAll()
  }

  /// Severs both sides of live dependency edges before this state leaves storage.
  ///
  /// Unlike context teardown, neighboring states survive this release. Removing
  /// their reverse edges is required both for invalidation correctness and for
  /// the context's unobserved-dependency cascade to become eligible.
  func releaseDependenciesForLifetime() {
    for dependency in dependencies {
      dependency.removeSubscriber(self)
    }
    dependencies.removeAll()
  }

  /// Makes state-owned work unable to publish before the storage slot is removed.
  ///
  /// Generation advances before cancellation because task bodies may ignore or
  /// outrun cooperative cancellation. The later storage-identity check supplies
  /// a second guard against a fresh state reusing the descriptor-and-key slot.
  func prepareForLifetimeRelease() {
    cancelPendingLifetimeRelease()
    resolveRefreshes(as: .released)
    _ = advanceGeneration()
    queuedRuns.removeAll(keepingCapacity: false)
    activeTask?.cancel()
    activeTask = nil
    activeRunGeneration = nil
  }

  /// Recaptures synchronous dependencies and starts the replacement generation.
  ///
  /// Settlement calls this only after dirty parents are current and while the
  /// state is marked as computing.
  func recompute(in cogs: Cogs) {
    startWork(in: cogs)
  }

  /// Runs synchronous selection, publishes pending, and installs newest work.
  ///
  /// Dependency reconciliation completes before the task is created, which is
  /// the boundary that prevents reads after suspension from becoming graph
  /// dependencies. `pendingTurn` is supplied by refresh so dependency capture
  /// and the pending transition belong to its already-open system turn.
  /// When selection occurs inside an active computing or tracking path, a first
  /// synchronous read installs its pending baseline immediately but queues the
  /// named turn until both paths unwind. This avoids reentrant Observation or
  /// reaction flushing while preserving diagnostic turn order.
  @discardableResult
  private func startWork(
    in cogs: Cogs,
    publishingPendingIn pendingTurn: CogTurn? = nil,
    refreshWaiter: CogRefreshWaiter<Value>? = nil
  ) -> UInt64 {
    guard isComputing else {
      fatalError("An async Cog selector ran outside the settle computation path.")
    }

    let previousDependencies = dependencies
    dependencies.removeAll(keepingCapacity: true)
    let work = cogs.tracking(self) {
      descriptor.makeWork(Reader(cogs: cogs, state: self), key: key)
    }

    for previousDependency in previousDependencies
    where !dependencies.contains(where: { $0 === previousDependency }) {
      previousDependency.removeSubscriber(self)
    }

    let operation = work.operation
    let runGeneration = advanceGeneration()

    switch descriptor.policy {
    case .queue:
      if let refreshWaiter {
        register(refreshWaiter, for: runGeneration)
      }
      let run = AsyncQueuedRun(generation: runGeneration, operation: operation)
      if activeTask == nil {
        beginQueuedRun(run, publishingPendingIn: pendingTurn, in: cogs)
      } else {
        queuedRuns.append(run)
        // Selection made this state current even though the request has not
        // started and therefore must not publish pending yet. Cleaning here is
        // also what lets a second source turn invalidate the state again and
        // append another distinct FIFO entry.
        markChecked(at: cogs.revision)
      }
    case .latest, .exhaustLatest, .merged:
      publishPending(in: cogs, in: pendingTurn)
      resolveRefreshes(as: .superseded)
      if let refreshWaiter {
        register(refreshWaiter, for: runGeneration)
      }
      activeTask?.cancel()
      launch(operation, generation: runGeneration, in: cogs)
    }
    return runGeneration
  }

  /// Publishes pending exactly when an accepted request starts executing.
  ///
  /// Queue selection may precede this call by several turns. Delaying pending
  /// keeps the visible lifecycle aligned with the one active run rather than
  /// claiming that work waiting in FIFO storage is already in flight.
  private func publishPending(in cogs: Cogs, in pendingTurn: CogTurn?) {
    let pending = CogStatus<Value>.pending(
      value: lastSuccess ?? descriptor.defaultValue,
      hasSucceeded: lastSuccess != nil
    )
    if let pendingTurn {
      pendingStatus = pending
      pendingTurn.touch(self)
    } else if status == nil {
      // A first read must synchronously return honest pending state. Nothing
      // can already subscribe to a state with no status, so install it now and
      // queue the named, otherwise-empty publication turn behind the active
      // graph operation without invalidating the reader that is establishing
      // its baseline.
      status = pending
      markChanged(at: cogs.revision)
      cogs.withSystemTurn("\(renderedName) pending") { _ in }
    } else {
      switch cogs.turnPhase {
      case .idle:
        // A cold state can be pulled while a new consumer is establishing its
        // baseline. Install pending for that read and defer only its named turn;
        // invalidating afterward would deliver the same pending status twice.
        status = pending
        markChanged(at: cogs.revision)
        cogs.withSystemTurn("\(renderedName) pending") { _ in }
      case .accumulating, .flushing:
        // A dependency-triggered reload starts as a later turn. While the
        // source turn is still flushing, readers continue to see its last
        // completed status; the queued pending turn invalidates them in order.
        stage(pending, named: "pending", in: cogs)
        markChecked(at: cogs.revision)
      }
    }
  }

  /// Starts the FIFO head after publishing that run's pending transition.
  private func beginQueuedRun(
    _ run: AsyncQueuedRun<Value>,
    publishingPendingIn pendingTurn: CogTurn? = nil,
    in cogs: Cogs
  ) {
    guard activeTask == nil, activeRunGeneration == nil else {
      fatalError("An async queue tried to start two runs at once.")
    }
    publishPending(in: cogs, in: pendingTurn)
    launch(run.operation, generation: run.generation, in: cogs)
  }

  /// Creates the sole task for one accepted one-shot generation.
  private func launch(
    _ operation: @escaping @Sendable @isolated(any) () async throws -> sending Value,
    generation runGeneration: UInt64,
    in cogs: Cogs
  ) {
    activeRunGeneration = runGeneration
    activeTask = Task(name: renderedName) { @MainActor [weak self, weak cogs] in
      do {
        let value = try await operation()
        guard let cogs else { return }
        defer { cogs.acknowledgeAsyncCompletionCheckIfRequested() }
        guard let self else { return }
        guard self.acceptsResult(for: runGeneration, in: cogs) else {
          self.resolveRefresh(for: runGeneration, as: .superseded)
          return
        }
        self.lastSuccess = .some(value)
        self.publish(.success(value), named: "success", in: cogs)
        self.resolveRefresh(for: runGeneration, as: .success(value))
        if self.descriptor.policy == .queue {
          self.startNextQueuedRun(in: cogs)
        }
      } catch {
        guard let cogs else { return }
        defer { cogs.acknowledgeAsyncCompletionCheckIfRequested() }
        guard let self else { return }
        guard !Task.isCancelled, self.acceptsResult(for: runGeneration, in: cogs)
        else {
          self.resolveRefresh(for: runGeneration, as: .superseded)
          return
        }
        self.publish(
          .failure(
            error,
            value: self.lastSuccess ?? self.descriptor.defaultValue,
            hasSucceeded: self.lastSuccess != nil
          ),
          named: "failure",
          in: cogs
        )
        self.resolveRefresh(for: runGeneration, as: .failure(error))
      }
    }
  }

  /// Removes and starts the next FIFO entry after the head succeeds.
  ///
  /// Failure continuation is intentionally left to M7-03c, whose scenario
  /// decides and proves that independently. This slice establishes serial FIFO
  /// start order for successful runs without absorbing that later repair.
  private func startNextQueuedRun(in cogs: Cogs) {
    guard !queuedRuns.isEmpty else { return }
    let run = queuedRuns.removeFirst()
    beginQueuedRun(run, in: cogs)
  }

  /// Files one explicit refresh cell under the generation it must follow.
  private func register(
    _ waiter: CogRefreshWaiter<Value>,
    for runGeneration: UInt64
  ) {
    guard refreshWaiters[runGeneration] == nil else {
      fatalError("An async Cog created two refresh handles for one generation.")
    }
    refreshWaiters[runGeneration] = waiter
  }

  /// Resolves and removes the explicit handle for one generation, if present.
  private func resolveRefresh(
    for runGeneration: UInt64,
    as outcome: CogRefresh<Value>.Outcome
  ) {
    refreshWaiters.removeValue(forKey: runGeneration)?.resolve(outcome)
  }

  /// Resolves and removes every explicit generation still awaiting a result.
  private func resolveRefreshes(as outcome: CogRefresh<Value>.Outcome) {
    let waiters = Array(refreshWaiters.values)
    refreshWaiters.removeAll(keepingCapacity: false)
    for waiter in waiters {
      waiter.resolve(outcome)
    }
  }

  /// Whether work selected from one generation may publish into current state.
  ///
  /// The active generation is newest under replacement policies and the FIFO
  /// head under queue policy. The stored-object and clean-state checks remain
  /// independent: an unobserved dirty state rejects work even when its task ID
  /// still matches, forcing the next consumer to select current dependencies.
  private func acceptsResult(for runGeneration: UInt64, in cogs: Cogs) -> Bool {
    let generationIsAccepted =
      switch descriptor.policy {
      case .queue:
        activeRunGeneration == runGeneration
      case .latest, .exhaustLatest, .merged:
        generation == runGeneration
      }
    guard generationIsAccepted, cogs.stillStoresAsyncState(self) else { return false }
    guard settleState == .clean else {
      activeTask = nil
      activeRunGeneration = nil
      markDirty()
      return false
    }
    return true
  }

  /// Advances the latest-work generation without allowing stale revival.
  ///
  /// Wraparound is a correctness failure: reusing zero could make ancient,
  /// cancellation-ignoring work appear current again.
  private func advanceGeneration() -> UInt64 {
    guard generation < UInt64.max else {
      fatalError("An async Cog exhausted its work generation counter.")
    }
    generation += 1
    return generation
  }

  /// Publishes one accepted work result as its own named system turn.
  ///
  /// Clearing the handle records that no current task remains; generation still
  /// guards any older task that outlived replacement cancellation. If graph
  /// evaluation is active, `stage` queues publication; completion never nests a
  /// turn into selector or reaction tracking.
  private func publish(_ status: CogStatus<Value>, named statusName: String, in cogs: Cogs) {
    activeTask = nil
    activeRunGeneration = nil
    stage(status, named: statusName, in: cogs)
  }

  /// Stages one status value into a named graph-owned turn.
  ///
  /// The body only fills the pending slot and touches this source. The ordinary
  /// turn flush performs visibility, invalidation, Observation, and reactions in
  /// the same order used by application commits.
  private func stage(_ status: CogStatus<Value>, named statusName: String, in cogs: Cogs) {
    cogs.withSystemTurn("\(renderedName) \(statusName)") { turn in
      self.pendingStatus = status
      turn.touch(self)
    }
  }

  /// Makes the staged status visible and invalidates status consumers atomically.
  ///
  /// Full status deliberately has no equality gate: pending, success, and
  /// failure are visible transitions even when their latest successful values
  /// compare equal. The ordinary value projection applies its own equality downstream.
  func flushPendingValue(in cogs: Cogs, at revision: CogVersion) {
    guard let pendingStatus else { return }
    self.pendingStatus = nil
    observationChanges = pendingStatus.observationChanges(from: status) {
      descriptor.valuesAreEqual($0, $1)
    }
    status = pendingStatus
    markChanged(at: revision)
    cogs.invalidateSubscribers(of: self)
  }

  /// Notifies only status fields changed by the completed publication turn.
  ///
  /// The field set is consumed once. A later turn recomputes it from that
  /// turn's prior and next atomic snapshots before Observation flush runs.
  func notifyObservationChange() {
    defer { observationChanges = [] }
    observationBoundary?.notifyStatusChanges(observationChanges)
  }

  /// The descriptor label plus key used consistently for turns and task tools.
  ///
  /// One rendering rule prevents task diagnostics from drifting from pending,
  /// success, and failure history names.
  private var renderedName: String {
    guard let key else { return "\(label)" }
    return "\(label)[\(key.erased.base)]"
  }

  // Written out, and `nonisolated`, per the generic-class release rule.
  nonisolated deinit {}
}

#endif
