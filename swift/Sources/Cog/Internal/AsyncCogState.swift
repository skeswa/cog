/// The live state behind one ``AsyncCog`` value reference in one context.
///
/// This is derived state with a split computation: the synchronous selector
/// captures graph dependencies, then its returned ``Work`` runs outside
/// dependency tracking. The state publishes pending, success, and failure as
/// separate system turns so readers and push consumers observe only completed
/// phase transitions.
internal final class AsyncCogState<Value>:
  CogState, CogConsumer, CogReaderState, DerivedCogSettleState, CogLifetimeLeaseState,
  CogObservationState, PendingCogSource
{
  /// The stable declaration shared by every copy of the value reference.
  let descriptor: AsyncCogDescriptor<Value>

  /// The keyed instance of `descriptor`, or `nil` for a keyless declaration.
  let key: AnyHashable?

  /// The declaration half of the context's descriptor-and-key storage identity.
  var descriptorIdentity: ObjectIdentifier { descriptor.identity }

  /// Whether settlement is currently running this state's synchronous selector.
  var isComputing = false

  /// Producers read by the latest synchronous selector run, in read order.
  ///
  /// Work-body reads cannot enter this list: tracking ends before ``Work``
  /// starts. A changed producer invalidates this state through its reverse edge,
  /// including while no durable consumer is present during lifetime grace.
  internal private(set) var dependencies: [any CogState] = []

  /// Fresh state is DIRTY so its first read selects and starts work.
  var settleState: CogSettleState = .dirty

  /// The revision of the last phase publication visible to readers.
  var changedAt: CogVersion = .initial

  /// The revision through which the selector and its dependencies are current.
  var checkedAt: CogVersion = .initial

  /// Weak reverse edges to phase or projection consumers.
  var subscribers: [CogSubscriberEdge] = []

  /// Created only when this exact async phase crosses the UI boundary.
  var observationBoundary: CogObservationBoundary?
  var observationKey: AnyHashable? { key }
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
  var stateIdentity: CogStateIdentity {
    CogStateIdentity(descriptor: descriptorIdentity, key: key)
  }

  /// The phase staged by a system turn but not yet published to readers.
  ///
  /// Like a manual source's pending value, this slot is consumed exactly once by
  /// ``flushPendingValue(in:at:)``. Keeping staging separate from `phase` makes
  /// each async transition atomic with the rest of its named turn.
  private var pendingPhase: CogPhase<Value>?

  /// The phase from the latest completed publication turn.
  ///
  /// Absence means this state has never settled. A successful settlement always
  /// gives the first caller honest pending rather than exposing an initial case.
  private var phase: CogPhase<Value>?

  /// The last accepted success, retained through pending and failure phases.
  ///
  /// ``Previous`` preserves a successful optional `nil` distinctly from no
  /// accepted success.
  private var lastSuccess: Previous<Value> = .none

  /// The cancellation handle for the newest requested `.latest` generation.
  ///
  /// Replaced tasks may ignore cancellation and continue running, but they are
  /// no longer reachable here and their generation cannot publish.
  private var activeTask: Task<Void, Never>?

  /// The monotonically increasing identity of the newest requested work.
  ///
  /// Starting replacement work and preparing lifetime release both advance it,
  /// so cancellation is never the correctness boundary for late completion.
  private var generation: UInt64 = 0

  var readerCurrentValue: CogPhase<Value>? { phase }

  init(descriptor: AsyncCogDescriptor<Value>, key: AnyHashable?) {
    self.descriptor = descriptor
    self.key = key
  }

  /// Settles dependencies and starts work when needed, then returns the latest
  /// completed phase publication.
  ///
  /// Both tracked and one-shot reads enter here. Therefore no read can bypass a
  /// dependency invalidation or observe state before initial pending exists.
  func settledPhase(in cogs: Cogtext) -> CogPhase<Value> {
    if let cycle = cogs.settleStack.cyclePath(ifEntering: self) {
      fatalError(cycle.message)
    }

    if settleState != .clean {
      cogs.settle(self)
    }

    guard let phase else {
      fatalError("A settled async Cog lost its phase.")
    }
    return phase
  }

  /// Forces the selector and work to run again under the normal settle path.
  ///
  /// A never-settled refresh is the initial demand and must not immediately
  /// replace the work it just started. Later refreshes use a named pending
  /// system turn, recapture dependencies, and follow the same generation rules
  /// as dependency-triggered replacement.
  func refresh(in cogs: Cogtext) {
    guard phase != nil else {
      _ = settledPhase(in: cogs)
      return
    }

    cogs.withSystemTurn("\(renderedName) pending") { turn in
      if let cycle = cogs.settleStack.cyclePath(ifEntering: self) {
        fatalError(cycle.message)
      }
      cogs.settleStack.beginComputing(self)
      defer { cogs.settleStack.endComputing(self) }
      self.startWork(in: cogs, publishingPendingIn: turn)
    }
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
    _ = advanceGeneration()
    activeTask?.cancel()
    activeTask = nil
  }

  /// Recaptures synchronous dependencies and starts the replacement generation.
  ///
  /// Settlement calls this only after dirty parents are current and while the
  /// state is marked as computing.
  func recompute(in cogs: Cogtext) {
    startWork(in: cogs)
  }

  /// Runs synchronous selection, publishes pending, and installs newest work.
  ///
  /// Dependency reconciliation completes before the task is created, which is
  /// the boundary that prevents reads after suspension from becoming graph
  /// dependencies. `pendingTurn` is supplied by refresh so dependency capture
  /// and the pending transition belong to its already-open system turn.
  private func startWork(in cogs: Cogtext, publishingPendingIn pendingTurn: CogTurn? = nil) {
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

    let pending = CogPhase<Value>.pending(previous: lastSuccess)
    if let pendingTurn {
      pendingPhase = pending
      pendingTurn.touch(self)
    } else if phase == nil {
      if cogs.canRunSystemTurnImmediately {
        stage(pending, named: "pending", in: cogs)
      } else {
        // A first read must synchronously return honest pending state. Nothing
        // can already subscribe to a state with no phase, so install it now and
        // queue the named, otherwise-empty publication turn behind the active
        // graph operation without invalidating the reader that is establishing
        // its baseline.
        phase = pending
        markChanged(at: cogs.revision)
        cogs.withSystemTurn("\(renderedName) pending") { _ in }
      }
    } else {
      switch cogs.turnPhase {
      case .idle where !cogs.canRunSystemTurnImmediately:
        // A cold state can be pulled while a new consumer is establishing its
        // baseline. Install pending for that read and defer only its named turn;
        // invalidating afterward would deliver the same pending phase twice.
        phase = pending
        markChanged(at: cogs.revision)
        cogs.withSystemTurn("\(renderedName) pending") { _ in }
      case .idle:
        stage(pending, named: "pending", in: cogs)
      case .accumulating, .flushing:
        // A dependency-triggered reload starts as a later turn. While the
        // source turn is still flushing, readers continue to see its last
        // completed phase; the queued pending turn invalidates them in order.
        stage(pending, named: "pending", in: cogs)
        markChecked(at: cogs.revision)
      }
    }

    let operation = work.operation
    let runGeneration = advanceGeneration()
    activeTask?.cancel()
    activeTask = Task(name: renderedName) { @MainActor [weak self, weak cogs] in
      do {
        let value = try await operation()
        guard let cogs else { return }
        defer { cogs.acknowledgeAsyncCompletionCheckIfRequested() }
        guard let self, self.acceptsResult(for: runGeneration, in: cogs)
        else { return }
        self.lastSuccess = .some(value)
        self.publish(.success(value), named: "success", in: cogs)
      } catch {
        guard let cogs else { return }
        defer { cogs.acknowledgeAsyncCompletionCheckIfRequested() }
        guard let self, !Task.isCancelled,
          self.acceptsResult(for: runGeneration, in: cogs)
        else { return }
        self.publish(.failure(error, previous: self.lastSuccess), named: "failure", in: cogs)
      }
    }
  }

  /// Whether work selected from one generation may publish into current state.
  ///
  /// All three conditions are necessary: the task is still newest, this exact
  /// object still occupies its descriptor-and-key slot, and no dependency has
  /// invalidated the selector inputs since work selection. An unobserved state
  /// stays lazy when a dependency changes, so old work can finish while it is
  /// DIRTY or CHECK. Rejecting that result and preserving DIRTY forces the next
  /// consumer to select fresh work instead of letting phase publication erase
  /// the pending invalidation.
  private func acceptsResult(for runGeneration: UInt64, in cogs: Cogtext) -> Bool {
    guard generation == runGeneration, cogs.stillStoresAsyncState(self) else { return false }
    guard settleState == .clean else {
      activeTask = nil
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
  /// guards any older task that outlived replacement cancellation.
  private func publish(_ phase: CogPhase<Value>, named phaseName: String, in cogs: Cogtext) {
    activeTask = nil
    stage(phase, named: phaseName, in: cogs)
  }

  /// Stages one phase into a named graph-owned turn.
  ///
  /// The body only fills the pending slot and touches this source. The ordinary
  /// turn flush performs visibility, invalidation, Observation, and reactions in
  /// the same order used by application commits.
  private func stage(_ phase: CogPhase<Value>, named phaseName: String, in cogs: Cogtext) {
    cogs.withSystemTurn("\(renderedName) \(phaseName)") { turn in
      self.pendingPhase = phase
      turn.touch(self)
    }
  }

  /// Makes the staged phase visible and invalidates phase consumers atomically.
  ///
  /// Full-phase state deliberately has no equality gate: pending, success, and
  /// failure are visible transitions even when their latest successful values
  /// compare equal. The `.latest` projection applies its own equality downstream.
  func flushPendingValue(in cogs: Cogtext, at revision: CogVersion) {
    guard let pendingPhase else { return }
    self.pendingPhase = nil
    phase = pendingPhase
    markChanged(at: revision)
    cogs.invalidateSubscribers(of: self)
  }

  /// The descriptor label plus key used consistently for turns and task tools.
  private var renderedName: String {
    guard let key else { return "\(label)" }
    return "\(label)[\(key.base)]"
  }

  // Written out, and `nonisolated`, per the generic-class release rule.
  nonisolated deinit {}
}
