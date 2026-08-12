/// One reaction registration owned by a context.
///
/// A reaction is a graph consumer but not readable graph state. The simple
/// correctness core nevertheless uses the narrow `CogNode` invalidation shape
/// for it: producers can hold the same weak reverse edge, and the reaction's
/// CLEAN/CHECK/DIRTY state says whether the end-of-turn pass may skip it, must
/// verify its derived dependencies, or knows a direct dependency changed.
internal final class CogReaction: CogNode, CogConsumer {
  let label: CogLabel

  /// The context that owns this registration, or `nil` once it is gone.
  ///
  /// Weak because ownership runs the other way: the context holds its
  /// registrations, so a strong link here would let one stored handle pin a
  /// whole graph. A token held past its context — one that outlived an
  /// isolated test runtime — must be able to cancel into nothing rather than
  /// keep that runtime alive or trap.
  private weak var cogs: Cogtext?

  /// What this registration runs, until cancellation releases it.
  ///
  /// Optional so that cancelling stops the reaction holding whatever its body
  /// captured — routinely the context itself — at the fixed stopping point
  /// rather than whenever the last handle happens to die.
  private var body: (@MainActor (ReactionReader) -> Void)?

  /// Whether this registration has been stopped.
  ///
  /// Its own flag rather than a value of `settleState`, because that state is
  /// written by the invalidation walk and again by `markChecked` at the end of
  /// every run: a cancellation encoded there would be erased by the next mark.
  private(set) var isCancelled = false

  /// Producers read by the last completed run, in read order.
  private(set) var dependencies: [any CogNode] = []

  /// Unique directly read derived roots this registration keeps observed.
  ///
  /// Kept separate from `dependencies`: that list preserves read order and
  /// repeats for graph recapture, while one reaction owns at most one lifetime
  /// lease for any node no matter how often its body reads it.
  private(set) var leasedDependencies: [any CogLifetimeLeaseNode] = []

  var settleState: CogSettleState = .clean
  var changedAt: CogVersion = .initial
  var checkedAt: CogVersion = .initial

  /// Reactions are terminal consumers. Keeping the standard slot empty lets
  /// the invalidation walk stop naturally when it reaches one.
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
  /// Two doors, and both have to shut. Dropping the reverse edges takes the
  /// reaction out of reach of the invalidation walk that would mark it, and
  /// removing the registration takes it out of the end-of-flush scan that turns
  /// a marked reaction into a queued run. Shutting only the first leaves a
  /// registration every later flush still walks; shutting only the second
  /// leaves a permanently dirty node pinning its producers.
  ///
  /// Neither door reaches a run this flush has already queued, which is what
  /// the flag is for: the queue holds its entries by value and a live cursor
  /// walks it, so entries are never removed from under that cursor. Every way
  /// into a run checks the flag instead.
  ///
  /// `settleState` is deliberately left alone. It belongs to the invalidation
  /// walk, and a cancelled reaction is out of the registration list with no
  /// edges left, so whatever it says is unobservable.
  ///
  /// The body is released here too, at this fixed stopping point. `run(in:)`
  /// binds an executing body to a local before user code can cancel itself, so
  /// clearing the stored copy cannot invalidate a closure already on stack.
  func cancel() {
    guard !isCancelled else { return }
    isCancelled = true
    releaseExternalLeases()
    body = nil

    for dependency in dependencies {
      dependency.removeSubscriber(self)
    }
    dependencies.removeAll()

    // A predicate removal rather than an index: the registration may already be
    // gone, and matching nothing is the no-op an index would not be. Survivors
    // keep their relative order, so registration order is undisturbed.
    cogs?.reactions.removeAll { $0 === self }
  }

  func recordDependency(on producer: any CogNode) {
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
  /// when at least one value really changed since its last completed run.
  func runIfNeeded(in cogs: Cogtext) {
    guard !isCancelled, settleState != .clean else { return }

    for dependency in dependencies {
      guard dependency.settleState != .clean,
        let derived = dependency as? any DerivedCogSettleNode
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
    // The one gate every path into a run passes, including a run this flush
    // queued before the cancellation. Bound to a local first, so a body that
    // cancels itself cannot release the closure it is executing inside.
    guard !isCancelled, let body = self.body else { return }

    // Recorded here, at the one place a reaction body executes, so that every
    // spelling of a registration lands under its own name: a `watch` given a
    // `name:` shows that name, and a registration that gave none shows the
    // file and line it was written on. A run whose watch suppressed its user
    // body — the quiet `.skip` install — is still a run Cog performed, and
    // still says so.
    #if DEBUG
    cogs.historyLog.recordEffect(label: label)
    cogs.quiescenceTracker.recordReaction(label: label)
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

    var nextLeasedDependencies: [any CogLifetimeLeaseNode] = []
    for dependency in dependencies {
      guard
        let leaseNode = dependency as? any CogLifetimeLeaseNode,
        leaseNode.lifetime == .whileObserved,
        !nextLeasedDependencies.contains(where: { $0 === leaseNode })
      else { continue }
      nextLeasedDependencies.append(leaseNode)
    }

    // Acquire additions before releasing removals so a retracking run swaps
    // ownership without an artificial zero-lease gap.
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
