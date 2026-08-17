/// Strength requested for one arena invalidation work item.
///
/// A direct subscriber is dirty because its own input changed. Descendants
/// only need checking because equality at that direct subscriber may stop the
/// wave before their value changes.
private nonisolated enum CogArenaInvalidationStrength: UInt8 {
  /// Something upstream may have changed.
  case check = 1

  /// One direct dependency changed.
  case dirty = 2
}

/// One scalar frame in the iterative arena invalidation walk.
private nonisolated struct CogArenaInvalidationFrame {
  /// Consumer row to mark.
  let row: Int32

  /// Minimum invalidation strength requested for that row.
  let strength: CogArenaInvalidationStrength
}

/// Pushes arena invalidation flags over indexed subscriber edges.
///
/// The context owns one instance and reuses its contiguous LIFO buffer across
/// turns. The walk carries only row indices and a scalar strength, so even deep
/// graphs use no recursion, state references, weak loads, or per-turn work-item
/// allocation after the buffer has reached its high-water mark.
@MainActor
internal final class CogArenaDirtyPropagation {
  /// Scalar rows whose flags this walk mutates.
  private let arena: CogArenaStorage

  /// Shared candidate pool supplying each producer's subscriber chain.
  private let edges: CogLinkedEdgePool

  /// Reused LIFO work storage; successful walks always drain it to zero.
  private var stack: ContiguousArray<CogArenaInvalidationFrame> = []

  /// Number of frames awaiting processing, exposed for infrastructure proofs.
  var stackCount: Int { stack.count }

  /// Retained high-water storage, exposed to prove later walks reuse it.
  var stackCapacity: Int { stack.capacity }

  /// Binds one invalidator to an arena and the edge pool containing its graph.
  init(arena: CogArenaStorage, edges: CogLinkedEdgePool) {
    self.arena = arena
    self.edges = edges
  }

  /// Whether `candidate` is the scalar arena this invalidator mutates.
  ///
  /// Typed columns check this before publishing, preventing equal row numbers
  /// from accidentally crossing isolated test or preview contexts.
  func belongs(to candidate: CogArenaStorage) -> Bool {
    arena === candidate
  }

  /// Marks every consumer downstream of one changed producer.
  ///
  /// Direct consumers request DIRTY; every later hop requests CHECK. A row
  /// already at equal or greater strength cuts off its branch, which preserves
  /// direct invalidation in diamonds and bounds repeated propagation from
  /// multiple changed sources in one turn.
  func invalidateSubscribers(of producer: CogArenaSlot) {
    _ = arena.index(of: producer)
    guard stack.isEmpty else {
      fatalError("Cog tried to reenter an arena invalidation walk.")
    }

    appendSubscribers(of: producer.index, requesting: .dirty)
    while let frame = stack.popLast() {
      guard mark(row: frame.row, atLeast: frame.strength) else { continue }
      appendSubscribers(of: frame.row, requesting: .check)
    }
  }

  /// Appends one producer's live subscriber rows at `strength`.
  private func appendSubscribers(
    of producerRow: Int32,
    requesting strength: CogArenaInvalidationStrength
  ) {
    guard producerRow >= 0, Int(producerRow) < arena.rowCount else {
      fatalError("Cog found an arena edge whose producer row was out of range.")
    }

    var cursor = arena.subs[Int(producerRow)]
    while cursor != .none {
      guard edges.contains(cursor) else {
        fatalError("Cog found a released entry in an arena subscriber list.")
      }
      let edge = edges.edges[Int(cursor.rawValue)]
      guard edge.dep == producerRow else {
        fatalError("Cog found another producer's edge in an arena subscriber list.")
      }
      stack.append(CogArenaInvalidationFrame(row: edge.sub, strength: strength))
      cursor = edge.nextSub
    }
  }

  /// Raises one live row to `strength`, returning whether its branch is new work.
  private func mark(row rawRow: Int32, atLeast strength: CogArenaInvalidationStrength) -> Bool {
    guard rawRow >= 0 else {
      fatalError("Cog found a negative consumer row in an arena edge.")
    }
    let row = Int(rawRow)
    guard row < arena.rowCount, arena.flags[row].contains(.occupied) else {
      fatalError("Cog tried to invalidate a released arena consumer row.")
    }

    var flags = arena.flags[row]
    guard !(flags.contains(.check) && flags.contains(.dirty)) else {
      fatalError("Cog found an arena row marked both CHECK and DIRTY.")
    }

    let currentStrength: CogArenaInvalidationStrength? =
      if flags.contains(.dirty) {
        .dirty
      } else if flags.contains(.check) {
        .check
      } else {
        nil
      }
    guard currentStrength?.rawValue ?? 0 < strength.rawValue else { return false }

    switch strength {
    case .check:
      flags.insert(.check)
    case .dirty:
      flags.remove(.check)
      flags.insert(.dirty)
    }
    arena.flags[row] = flags
    return true
  }
}
