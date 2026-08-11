/// One monotonic graph revision in the simple correctness core.
///
/// A node's `changedAt` records the last revision in which its value really
/// changed. Its `checkedAt` records the last revision through which Cog proved
/// the value current, including a recomputation that landed equal. Keeping the
/// two separate is what lets an equal middle node stop a downstream
/// wave (§2.4, perf §3.4).
///
/// The class-node core uses a wide scalar and leaves the compact integer
/// layout to M6's measured arena. The type itself is nonisolated because a
/// revision is inert data even though the context that advances it is not.
internal nonisolated struct CogVersion: Comparable, Sendable {
  /// Before any turn has advanced the graph.
  static let initial = CogVersion(rawValue: 0)

  private let rawValue: UInt64

  static func < (lhs: CogVersion, rhs: CogVersion) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  /// The next revision, failing loudly instead of silently wrapping and
  /// making ancient values look newer than current ones.
  func advanced() -> CogVersion {
    guard rawValue < UInt64.max else {
      fatalError("Cog exhausted its graph revision counter.")
    }
    return CogVersion(rawValue: rawValue + 1)
  }
}

/// How much work a node is known to need before its value may be returned.
///
/// The order is a strength lattice used by push propagation:
///
/// - `clean`: the cached value is current;
/// - `check`: something upstream may have changed, so settle parents and
///   compare their versions;
/// - `dirty`: a direct dependency changed, so the node must recompute after
///   its parents settle.
///
/// A weaker invalidation never replaces a stronger one. In particular, a
/// transitive CHECK path cannot erase a direct DIRTY path in a diamond.
internal enum CogSettleState: UInt8, Comparable {
  case clean
  case check
  case dirty

  static func < (lhs: CogSettleState, rhs: CogSettleState) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

/// One weak reverse edge in the class-node correctness core.
///
/// A derived node strongly owns the producers in its dependency list. Keeping
/// the reverse edge weak prevents those two arrays from forming a retain cycle
/// when a context or, later, a released node lets the graph go.
internal final class CogSubscriberEdge {
  weak var node: (any CogNode)?

  init(_ node: any CogNode) {
    self.node = node
  }
}

extension CogNode {
  /// Adds one reverse edge, reusing the existing edge when a stable selector
  /// reads the same producer again.
  func addSubscriber(_ consumer: any CogNode) {
    subscribers.removeAll { $0.node == nil }
    guard !subscribers.contains(where: { $0.node === consumer }) else { return }
    subscribers.append(CogSubscriberEdge(consumer))
  }

  /// Records possible upstream work without weakening an existing DIRTY mark.
  func markForCheck() {
    if settleState < .check {
      settleState = .check
    }
  }

  /// Records that a direct dependency changed and recomputation is required.
  func markDirty() {
    settleState = .dirty
  }

  /// Records that the node was checked through `version` and stayed equal.
  func markChecked(at version: CogVersion) {
    checkedAt = version
    settleState = .clean
  }

  /// Records that the node's current value changed in `version`.
  func markChanged(at version: CogVersion) {
    changedAt = version
    checkedAt = version
    settleState = .clean
  }
}

/// The type-erased capabilities only a derived node needs during settlement.
///
/// The explicit stack holds heterogeneous nodes. This protocol lets its exit
/// frame inspect a derived node's parents and rerun a generic selector without
/// erasing the selector's value at each graph edge.
@MainActor
internal protocol DerivedCogSettleNode: CogNode {
  var dependencies: [any CogNode] { get }
  func recompute(in cogs: Cogtext)
}

/// One half of the iterative pull walk.
///
/// Enter frames inspect a node and schedule its parents. The matching exit
/// frame runs only after those parents, which is where the later settle task
/// compares versions and, when needed, recomputes the node. Keeping both
/// actions in one erased frame type lets the class-node core walk arbitrarily
/// typed nodes without recursive Swift calls.
internal enum CogSettleFrame {
  case enter(any CogNode)
  case exit(any CogNode)
}

/// The context-owned frame buffer reused by every settle walk.
///
/// `reset` deliberately clears with retained capacity. Normal completion pops
/// the buffer empty already, while the clear also makes a later traversal safe
/// after an early diagnostic path abandoned frames. The final arena core will
/// replace node references with slots without changing the enter/exit shape.
internal struct CogSettleStack {
  private var frames: [CogSettleFrame] = []

  var count: Int { frames.count }
  var capacity: Int { frames.capacity }
  var isEmpty: Bool { frames.isEmpty }

  mutating func reset(startingAt root: any CogNode) {
    frames.removeAll(keepingCapacity: true)
    frames.append(.enter(root))
  }

  mutating func pushEnter(_ node: any CogNode) {
    frames.append(.enter(node))
  }

  mutating func pushExit(_ node: any CogNode) {
    frames.append(.exit(node))
  }

  mutating func popLast() -> CogSettleFrame? {
    frames.popLast()
  }
}

extension Cogtext {
  /// Pushes invalidation away from a node whose value really changed.
  ///
  /// Direct consumers become DIRTY because one of their own inputs changed.
  /// Nodes farther downstream become CHECK because equality may stop the wave
  /// before it reaches them. The local work list keeps even a deep subscriber
  /// chain off the Swift call stack.
  internal func invalidateSubscribers(of producer: any CogNode) {
    var work: [(any CogNode, CogSettleState)] = []
    for edge in producer.subscribers {
      if let subscriber = edge.node {
        work.append((subscriber, .dirty))
      }
    }

    while let (node, requestedState) = work.popLast() {
      guard node.settleState < requestedState else { continue }

      node.settleState = requestedState
      for edge in node.subscribers {
        if let subscriber = edge.node {
          work.append((subscriber, .check))
        }
      }
    }
  }

  /// Pulls one cached derived root current through iterative enter/exit frames.
  ///
  /// Enter schedules dirty parents before their consumer. Exit then uses
  /// `changedAt` versus the consumer's prior `checkedAt` to decide whether a
  /// CHECK node must run. A recomputation that lands equal advances only
  /// `checkedAt`, so consumers farther down a CHECK wave stay cached.
  internal func settle(_ root: any DerivedCogSettleNode) {
    settleStack.reset(startingAt: root)

    while let frame = settleStack.popLast() {
      switch frame {
      case .enter(let node):
        guard node.settleState != .clean else { continue }
        guard let derived = node as? any DerivedCogSettleNode else {
          // Sources are settled when their pending value moves to current, so
          // an invalid source here would be an internal propagation mistake.
          node.markChecked(at: revision)
          continue
        }

        settleStack.pushExit(derived)
        for dependency in derived.dependencies.reversed()
        where dependency.settleState != .clean {
          settleStack.pushEnter(dependency)
        }

      case .exit(let node):
        guard let derived = node as? any DerivedCogSettleNode else { continue }

        let parentChanged = derived.dependencies.contains {
          $0.changedAt > derived.checkedAt
        }

        if derived.settleState == .dirty || parentChanged {
          derived.recompute(in: self)
        } else {
          derived.markChecked(at: revision)
        }
      }
    }
  }
}
