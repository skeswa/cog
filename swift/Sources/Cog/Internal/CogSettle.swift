/// One monotonic graph revision in the simple correctness core.
///
/// A node's `changedAt` records the last revision in which its value really
/// changed. Its `checkedAt` records the last revision through which Cog proved
/// the value current, including a recomputation that landed equal. Keeping the
/// two separate is what later lets an equal middle node stop a downstream
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

extension CogNode {
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
