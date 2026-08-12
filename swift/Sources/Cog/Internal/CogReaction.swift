/// One reaction registration owned by a context.
///
/// A reaction is a consumer, not readable state. It conforms to `CogState` so
/// producers can use the same reverse edges and invalidation marks.
internal final class CogReaction: CogState, CogConsumer {
  let label: CogLabel

  /// The context that owns this registration, or `nil` once it is gone.
  ///
  /// Weak because the context owns its registrations. A token may outlive an
  /// isolated test context without keeping that graph alive.
  private weak var cogs: Cogtext?

  /// What this registration runs, until cancellation releases it.
  ///
  /// Cancellation clears the body and releases its captures immediately.
  private var body: (@MainActor (ReactionReader) -> Void)?

  /// Whether this registration has been stopped.
  ///
  /// Separate from `settleState`, which invalidation and settlement overwrite.
  private(set) var isCancelled = false

  /// Producers read by the last completed run, in read order.
  private(set) var dependencies: [any CogState] = []

  /// Unique directly read derived roots this registration keeps observed.
  ///
  /// Separate from `dependencies` because repeated reads still own one lease.
  private(set) var leasedDependencies: [any CogLifetimeLeaseState] = []

  var settleState: CogSettleState = .clean
  var changedAt: CogVersion = .initial
  var checkedAt: CogVersion = .initial

  /// Reactions are terminal consumers, so invalidation stops here.
  var subscribers: [CogSubscriberEdge] = []

  init(
    cogs: Cogtext,
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

  func recordDependency(on producer: any CogState) {
    // A body that cancels itself and then keeps reading must not attach a new
    // edge to a registration that is already out of the graph.
    guard !isCancelled else { return }

    dependencies.append(producer)
    producer.addSubscriber(self)
  }

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
  func runInitially(in cogs: Cogtext) {
    run(in: cogs)
  }

  /// Settles the hot dependencies of a reachable reaction and reruns it only
  /// when at least one value changed since its last completed run.
  func runIfNeeded(in cogs: Cogtext) {
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
  private func run(in cogs: Cogtext) {
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
  }

  /// Replaces this registration's lease set after one completed tracking run.
  private func reconcileExternalLeases(in cogs: Cogtext) {
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
internal enum CogReactionRun {
  case changed(CogReaction)
  case initial(CogReaction)

  func perform(in cogs: Cogtext) {
    switch self {
    case .changed(let reaction):
      reaction.runIfNeeded(in: cogs)
    case .initial(let reaction):
      reaction.runInitially(in: cogs)
    }
  }
}
