/// One reaction registration owned by a context.
///
/// A reaction is a graph consumer but not readable graph state. The simple
/// correctness core nevertheless uses the narrow `CogNode` invalidation shape
/// for it: producers can hold the same weak reverse edge, and the reaction's
/// CLEAN/CHECK/DIRTY state says whether the end-of-turn pass may skip it, must
/// verify its derived dependencies, or knows a direct dependency changed.
internal final class CogReaction: CogNode, CogConsumer {
  let label: CogLabel

  private let body: @MainActor (ReactionReader) -> Void

  /// Producers read by the last completed run, in read order.
  private(set) var dependencies: [any CogNode] = []

  var settleState: CogSettleState = .clean
  var changedAt: CogVersion = .initial
  var checkedAt: CogVersion = .initial

  /// Reactions are terminal consumers. Keeping the standard slot empty lets
  /// the invalidation walk stop naturally when it reaches one.
  var subscribers: [CogSubscriberEdge] = []

  init(label: CogLabel, body: @escaping @MainActor (ReactionReader) -> Void) {
    self.label = label
    self.body = body
  }

  func recordDependency(on producer: any CogNode) {
    dependencies.append(producer)
    producer.addSubscriber(self)
  }

  /// Runs once at registration to establish the first dependency set.
  func runInitially(in cogs: Cogtext) {
    run(in: cogs)
  }

  /// Settles the hot dependencies of a reachable reaction and reruns it only
  /// when at least one value really changed since its last completed run.
  func runIfNeeded(in cogs: Cogtext) {
    guard settleState != .clean else { return }

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
    let previousDependencies = dependencies
    dependencies.removeAll(keepingCapacity: true)

    cogs.tracking(self) {
      body(ReactionReader(cogs: cogs, reaction: self))
    }

    for previousDependency in previousDependencies
    where !dependencies.contains(where: { $0 === previousDependency }) {
      previousDependency.removeSubscriber(self)
    }

    markChecked(at: cogs.revision)
  }
}
