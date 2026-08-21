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

/// Pushes arena invalidation flags through the shared linked-edge pool.
///
/// The context owns one instance and reuses its contiguous LIFO buffer across
/// turns. The walk carries only row indices and a scalar strength, so even deep
/// graphs use no recursion, state references, weak loads, or per-turn work-item
/// allocation after the buffer has reached its high-water mark.
@MainActor
#if !COG_ARENA_COMPACT
@usableFromInline
#endif
internal final class CogArenaDirtyPropagation {
  /// Scalar rows whose flags this walk mutates.
  private let arena: CogArenaStorage

  /// Shared pool supplying each producer's subscriber chain.
  private let edges: CogLinkedEdgePool

  /// Rows whose UI boundary could have changed in the accumulating turn.
  ///
  /// The flush walks this instead of every boundary the context has ever made,
  /// which is what makes a turn cost O(changed) rather than O(pinned keys). The
  /// buffer is reused across turns like the walk's own stack.
  // Unchecked for the reason `CogArenaStorage` records; every element is trivial.
  @exclusivity(unchecked)
  private var changedBoundaryRows: ContiguousArray<Int32> = []

  /// Reused LIFO work storage; successful walks always drain it to zero.
  // Unchecked for the reason `CogArenaStorage` records; every element is trivial.
  @exclusivity(unchecked)
  private var stack: ContiguousArray<CogArenaInvalidationFrame> = []

  /// Number of frames awaiting processing, exposed for infrastructure proofs.
  var stackCount: Int { stack.count }

  /// Retained high-water storage, exposed to prove later walks reuse it.
  var stackCapacity: Int { stack.capacity }

  /// Binds one invalidator to an arena and the edge storage containing its graph.
  init(arena: CogArenaStorage, edges: CogLinkedEdgePool) {
    self.arena = arena
    self.edges = edges
  }

  /// Whether `candidate` is the scalar arena this invalidator mutates.
  ///
  /// Typed columns check this before publishing, preventing equal row numbers
  /// from accidentally crossing isolated test or preview contexts.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  func belongs(to candidate: CogArenaStorage) -> Bool {
    arena === candidate
  }

  /// Marks every consumer downstream of one changed producer.
  ///
  /// Direct consumers request DIRTY; every later hop requests CHECK. A row
  /// already at equal or greater strength cuts off its branch, which preserves
  /// direct invalidation in diamonds and bounds repeated propagation from
  /// multiple changed sources in one turn.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  func invalidateSubscribers(of producer: CogArenaSlot) {
    _ = arena.index(of: producer)
    guard stack.isEmpty else {
      fatalError("Cog tried to reenter an arena invalidation walk.")
    }

    // The producer changed by definition; `mark` catches everything downstream
    // that could. Between them they are exactly the boundaries a flush has any
    // reason to visit, which is what makes the flush O(changed keys).
    enqueueBoundaryNotice(row: producer.index)

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

    guard producerRow >= 0, Int(producerRow) < arena.rowCount else {
      fatalError("Cog found an arena edge whose producer row was out of range.")
    }

    var cursor = arena.subs[Int(producerRow)]
    while cursor != .none {
      let edge = edges.edge(at: cursor)
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
    enqueueBoundaryNotice(row: rawRow)
    return true
  }

  /// Queues one row's boundary notice, if it has a boundary and is not queued.
  ///
  /// Both tests are scalar loads on a row this walk already holds, so a graph
  /// with no UI boundaries pays two loads and a branch per marked row.
  private func enqueueBoundaryNotice(row rawRow: Int32) {
    let row = Int(rawRow)
    guard row >= 0, row < arena.rowCount else { return }
    guard arena.boundary[row] != CogArenaStorage.noIndex else { return }
    guard !arena.flags[row].contains(.noticeQueued) else { return }

    arena.flags[row].insert(.noticeQueued)
    changedBoundaryRows.append(rawRow)
  }

  /// Whether any boundary was invalidated in the accumulating turn.
  var hasChangedBoundaryRows: Bool { !changedBoundaryRows.isEmpty }

  /// Rows queued so far, in notice order.
  ///
  /// Sorted in place and read by index rather than handed back as a value.
  /// Returning it copied the buffer — the same copy-on-write mistake `M9-09`
  /// found in the dependency list, made again here — because the property kept
  /// its own reference and the caller's sort then had to reallocate.
  var changedBoundaryRowCount: Int { changedBoundaryRows.count }

  /// Puts the queued rows in the order their boundaries were created.
  func sortChangedBoundaryRows(by areInOrder: (Int32, Int32) -> Bool) {
    changedBoundaryRows.sort(by: areInOrder)
  }

  /// The queued row at `position`.
  func changedBoundaryRow(at position: Int) -> Int32 {
    changedBoundaryRows[position]
  }

  /// Drops the rows a flush has published, keeping anything queued during it.
  func dropFlushedBoundaryRows(_ count: Int) {
    changedBoundaryRows.removeFirst(count)
  }

  /// Clears one row's queued mark once the flush has published it.
  func clearBoundaryNotice(row rawRow: Int32) {
    let row = Int(rawRow)
    guard row >= 0, row < arena.rowCount else { return }
    arena.flags[row].remove(.noticeQueued)
  }

  // Written out, and `nonisolated`, so deallocation does not ask the
  // concurrency runtime to hop to the MainActor.
  nonisolated deinit {}
}
