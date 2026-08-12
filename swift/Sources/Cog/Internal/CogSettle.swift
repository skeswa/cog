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

  /// Removes the reverse edge for a consumer that did not read this producer
  /// on its latest run, while also pruning subscribers that have gone away.
  func removeSubscriber(_ consumer: any CogNode) {
    subscribers.removeAll { edge in
      guard let subscriber = edge.node else { return true }
      return subscriber === consumer
    }
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
  /// The declaration half of this node's stable descriptor-and-key identity.
  var descriptorIdentity: ObjectIdentifier { get }

  /// The key half of this node's identity, or `nil` for a keyless declaration.
  var key: AnyHashable? { get }

  /// Whether this node is on the context's active derived-computation path.
  var isComputing: Bool { get set }

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

/// The context-owned traversal storage reused by every settle walk.
///
/// Nested pulls append frames above their caller's checkpoint and pop only
/// that suffix, while the active derived path remains shared so either walk
/// can recognize a cycle through the other. The final arena core will replace
/// node references with slots without changing the enter/exit/path shape.
internal struct CogSettleStack {
  private var frames: [CogSettleFrame] = []
  private var computingPath: [any DerivedCogSettleNode] = []

  var count: Int { frames.count }
  var capacity: Int { frames.capacity }
  var isEmpty: Bool { frames.isEmpty }
  var computingCount: Int { computingPath.count }
  var isComputingEmpty: Bool { computingPath.isEmpty }

  /// The innermost cog whose derived computation has not published yet.
  ///
  /// Commit rejection uses only this exceptional-path lookup. Ordinary reads
  /// and turns continue to pay the per-node Boolean check alone.
  var innermostComputingNode: (any DerivedCogSettleNode)? {
    computingPath.last
  }

  /// Resets only the raw frame buffer for low-level stack infrastructure tests.
  /// Production settlement uses checkpoints so a nested pull preserves its
  /// caller's pending frames and active computation path.
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

  /// The cycle that entering `node` would close, or `nil` for a new path step.
  ///
  /// Every ordinary check is the node's one Boolean. Only the exceptional
  /// marked-node path scans the active stack and snapshots the actual cycle
  /// suffix, so normal reads allocate and render nothing.
  func cyclePath(ifEntering node: any DerivedCogSettleNode) -> CogCyclePath? {
    guard node.isComputing else { return nil }
    guard let first = computingPath.firstIndex(where: { $0 === node }) else {
      fatalError("A derived Cog was marked computing without an active path entry.")
    }

    return CogCyclePath(nodes: Array(computingPath[first...]) + [node])
  }

  /// Marks and appends one derived node after cycle detection has succeeded.
  mutating func beginComputing(_ node: any DerivedCogSettleNode) {
    guard cyclePath(ifEntering: node) == nil else {
      fatalError("Cog tried to enter a derived cycle without reporting it.")
    }
    node.isComputing = true
    computingPath.append(node)
  }

  /// Clears the last derived path entry, enforcing balanced LIFO traversal.
  mutating func endComputing(_ node: any DerivedCogSettleNode) {
    guard let active = computingPath.last, active === node else {
      fatalError("Cog tried to finish derived computation out of path order.")
    }
    computingPath.removeLast()
    node.isComputing = false
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
    // A selector may discover a dirty dependency while an outer settle still
    // has sibling and exit frames pending. Appending above a checkpoint keeps
    // that nested pull from erasing its caller's work; each invocation pops
    // only the frames it owns.
    let boundary = settleStack.count
    settleStack.pushEnter(root)

    while settleStack.count > boundary, let frame = settleStack.popLast() {
      switch frame {
      case .enter(let node):
        guard node.settleState != .clean else { continue }
        guard let derived = node as? any DerivedCogSettleNode else {
          // Sources are settled when their pending value moves to current, so
          // an invalid source here would be an internal propagation mistake.
          node.markChecked(at: revision)
          continue
        }

        if let cycle = settleStack.cyclePath(ifEntering: derived) {
          fatalError(cycle.message)
        }

        settleStack.beginComputing(derived)
        settleStack.pushExit(derived)
        for dependency in derived.dependencies.reversed()
        where dependency.settleState != .clean {
          settleStack.pushEnter(dependency)
        }

      case .exit(let node):
        guard let derived = node as? any DerivedCogSettleNode else { continue }
        defer { settleStack.endComputing(derived) }

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
