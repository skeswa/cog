/// One reaction registration owned by a context.
///
/// A reaction is a consumer, not readable state. It conforms to `CogState` so
/// producers can use the same reverse edges and invalidation marks. The owning
/// MainActor context orders registrations, runs them after UI settlement, and
/// keeps only the durable derived roots they directly read externally leased.
internal final class CogReaction: CogState, CogConsumer {
  /// The stable diagnostic identity supplied at registration.
  let label: CogLabel

  /// The context that owns this registration, or `nil` once it is gone.
  ///
  /// Weak because the context owns its registrations. A token may outlive an
  /// isolated test context without keeping that graph alive.
  private weak var cogs: Cogs?

  /// What this registration runs, until cancellation releases it.
  ///
  /// Cancellation clears the body and releases its captures immediately.
  private var body: (@MainActor (ReactionReader) -> Void)?

  /// Whether this registration has been stopped.
  ///
  /// Separate from `settleState`, which invalidation and settlement overwrite.
  private(set) var isCancelled = false

  /// Producers read by the last completed run, in read order.
  ///
  /// Strong ownership keeps the producer graph alive while registered; each
  /// producer stores only one weak reverse edge back to this reaction.
  private(set) var dependencies: [any CogState] = []

  /// Unique directly read derived roots this registration keeps observed.
  ///
  /// Separate from `dependencies` because repeated reads still own one lease.
  private(set) var leasedDependencies: [any CogLifetimeLeaseState] = []

  /// Whether invalidation requires this terminal consumer to check or rerun.
  var settleState: CogSettleState = .clean

  /// The last revision in which a reaction body was treated as changed.
  ///
  /// Reactions do not publish a value, so this remains the initial revision;
  /// direct DIRTY state, not `changedAt`, forces a run.
  var changedAt: CogVersion = .initial

  /// The graph revision against which the last completed body run was checked.
  var checkedAt: CogVersion = .initial

  /// Reactions are terminal consumers, so invalidation stops here.
  var subscribers: [CogSubscriberEdge] = []

  /// Creates an inert registration; the context installs and initially runs it
  /// in registration order after ownership is established.
  init(
    cogs: Cogs,
    label: CogLabel,
    body: @escaping @MainActor (ReactionReader) -> Void
  ) {
    self.cogs = cogs
    self.label = label
    self.body = body
  }

  /// Stops this registration and takes it out of the graph.
  ///
  /// Remove both dependency edges and the context registration. Leaving either
  /// would retain graph state or keep later flushes scanning the reaction.
  ///
  /// Queued runs remain in the array, so every run checks `isCancelled`.
  ///
  /// `settleState` is irrelevant after the reaction leaves the graph.
  ///
  /// `run(in:)` keeps an executing body in a local, so self-cancellation cannot
  /// release the closure on the stack.
  func cancel() {
    guard !isCancelled else { return }
    isCancelled = true
    releaseExternalLeases()
    body = nil

    for dependency in dependencies {
      dependency.removeSubscriber(self)
    }
    dependencies.removeAll()

    // Predicate removal also handles an already-removed registration and keeps
    // survivor order.
    cogs?.reactions.removeAll { $0 === self }
  }

  /// Records a body read and installs its reverse invalidation edge.
  func recordDependency(on producer: any CogState) {
    // A body that cancels itself and then keeps reading must not attach a new
    // edge to a registration that is already out of the graph.
    guard !isCancelled else { return }

    dependencies.append(producer)
    producer.addSubscriber(self)
  }

  /// Balances external leases and drops strong edges during context teardown.
  ///
  /// This bypasses normal grace scheduling because no state in the context can
  /// survive the same isolated deinitialization pass.
  func releaseDependenciesForContextTeardown() {
    // The context is already ending, so balance the inert counts directly and
    // never enter the normal release path that later schedules grace work.
    for dependency in leasedDependencies {
      dependency.decrementExternalLeaseCount()
    }
    leasedDependencies.removeAll()
    dependencies.removeAll()
  }

  /// Runs once at registration to establish the first dependency set.
  ///
  /// Initial runs share the active flush's ordered reaction queue when created
  /// during a turn, preventing them from overtaking already-invalidated effects.
  func runInitially(in cogs: Cogs) {
    run(in: cogs)
  }

  /// Settles the hot dependencies of a reachable reaction and reruns it only
  /// when at least one value changed since its last completed run.
  ///
  /// CHECK dependencies settle first. If they all prove equal, advancing only
  /// this reaction's `checkedAt` stops work without invoking user code.
  func runIfNeeded(in cogs: Cogs) {
    guard !isCancelled, settleState != .clean else { return }

    for dependency in dependencies {
      guard dependency.settleState != .clean,
        let derived = dependency as? any DerivedCogSettleState
      else { continue }
      cogs.settle(derived)
    }

    let dependencyChanged = dependencies.contains {
      $0.changedAt > checkedAt
    }

    if settleState == .dirty || dependencyChanged {
      run(in: cogs)
    } else {
      markChecked(at: cogs.revision)
    }
  }

  /// Captures a fresh dependency set around one synchronous body run.
  ///
  /// Dependency edges and lease ownership reconcile before the final checked
  /// mark. Any system turns requested by async reads inside the body drain only
  /// afterward, when tracking and the derived computing path are both empty.
  private func run(in cogs: Cogs) {
    // Every run checks cancellation. The local keeps the closure alive through
    // self-cancellation.
    guard !isCancelled, let body = self.body else { return }

    // Record every reaction run, including a watch's quiet `.skip` install.
    #if DEBUG
    cogs.historyLog.recordEffect(label: label)
    cogs.turnChainTracker.recordReaction(label: label)
    #endif

    let previousDependencies = dependencies
    dependencies.removeAll(keepingCapacity: true)

    cogs.tracking(self) {
      body(ReactionReader(cogs: cogs, reaction: self))
    }

    for previousDependency in previousDependencies
    where !dependencies.contains(where: { $0 === previousDependency }) {
      previousDependency.removeSubscriber(self)
    }

    reconcileExternalLeases(in: cogs)

    markChecked(at: cogs.revision)
    cogs.drainQueuedTurnsIfPossible()
  }

  /// Replaces this registration's lease set after one completed tracking run.
  private func reconcileExternalLeases(in cogs: Cogs) {
    // Self-cancellation releases the old set immediately. Reads after that
    // point are ignored, and finishing the now-cancelled run must not acquire
    // anything again.
    guard !isCancelled else { return }

    var nextLeasedDependencies: [any CogLifetimeLeaseState] = []
    for dependency in dependencies {
      guard
        let leaseState = dependency as? any CogLifetimeLeaseState,
        case .whileObserved = leaseState.lifetime,
        !nextLeasedDependencies.contains(where: { $0 === leaseState })
      else { continue }
      nextLeasedDependencies.append(leaseState)
    }

    // Acquire additions first to avoid a false zero-lease gap.
    for dependency in nextLeasedDependencies
    where !leasedDependencies.contains(where: { $0 === dependency }) {
      cogs.acquireExternalLease(on: dependency)
    }
    for dependency in leasedDependencies
    where !nextLeasedDependencies.contains(where: { $0 === dependency }) {
      cogs.releaseExternalLease(on: dependency)
    }

    leasedDependencies = nextLeasedDependencies
  }

  /// Releases every lease at explicit cancellation or final token cleanup.
  private func releaseExternalLeases() {
    if let cogs {
      for dependency in leasedDependencies {
        cogs.releaseExternalLease(on: dependency)
      }
    } else {
      // A context normally clears this list during its isolated deinit. Keep a
      // raw balancing fallback so a retained token cannot hide an invariant if
      // its weak owner has already disappeared.
      for dependency in leasedDependencies {
        dependency.decrementExternalLeaseCount()
      }
    }
    leasedDependencies.removeAll()
  }
}

/// One entry in the active flush's registration-ordered reaction queue.
///
/// Changed registrations precede initial registrations appended during that
/// flush. Each entry rechecks cancellation when performed, since cancellation
/// intentionally does not mutate the queue being iterated.
internal enum CogReactionRun {
  /// Reconsider a previously registered reaction after invalidation.
  case changed(CogReaction)

  /// Establish dependencies for a registration created during this flush.
  case initial(CogReaction)

  /// Performs the queued run using the mode captured when it was enqueued.
  func perform(in cogs: Cogs) {
    switch self {
    case .changed(let reaction):
      reaction.runIfNeeded(in: cogs)
    case .initial(let reaction):
      reaction.runInitially(in: cogs)
    }
  }
}
