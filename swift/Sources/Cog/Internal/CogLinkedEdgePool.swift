/// Index of one entry in ``CogLinkedEdgePool``.
///
/// `-1` is the universal list terminator. Live indices are dense non-negative
/// `Int32` values so arena scalar rows and edge entries can link without ARC,
/// optional payloads, or pointer-sized storage.
#if !COG_ARENA_COMPACT
@usableFromInline
#endif
internal nonisolated struct CogEdgeIndex: Hashable, Sendable {
  /// Position in the pool's contiguous entry array, or `-1` for no edge.
  let rawValue: Int32

  /// End of a dependency, subscriber, or free list.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  static let none = CogEdgeIndex(rawValue: -1)
}

/// One edge shared by a producer's subscriber list and a consumer's dependency list.
///
/// The producer side is doubly linked for O(1) reverse unlink. The consumer
/// side preserves selector read order with one forward link. Six four-byte
/// fields keep the selected representation at the 24-byte shape proposed by perf
/// §3.3.
internal nonisolated struct CogPoolEdge: Sendable {
  /// Producer arena slot.
  var dep: Int32

  /// Consumer arena slot.
  var sub: Int32

  /// Newer entry in the producer's subscriber list.
  var prevSub: CogEdgeIndex

  /// Older entry in the producer's subscriber list.
  var nextSub: CogEdgeIndex

  /// Next producer read by this consumer.
  ///
  /// A free entry reuses this field as the next free-list index.
  var nextDep: CogEdgeIndex

  /// Producer change version captured when the consumer last read it.
  var version: UInt32

  /// Whether this entry currently belongs to both graph lists.
  var isLive: Bool { dep >= 0 && sub >= 0 }

  /// Creates one cleared entry whose dependency link joins the free list.
  static func free(next: CogEdgeIndex) -> CogPoolEdge {
    CogPoolEdge(
      dep: -1,
      sub: -1,
      prevSub: .none,
      nextSub: .none,
      nextDep: next,
      version: 0
    )
  }
}

/// Shared linked-edge storage for the arena.
///
/// Adding an edge appends to one consumer's ordered dependency list and pushes
/// onto one producer's subscriber list. Removal repairs both topologies before
/// reusing the entry itself as a free-list node. The pool owns no states and
/// stores no references; arena slots must remain live until their edges have
/// been removed.
@MainActor
#if !COG_ARENA_COMPACT
@usableFromInline
#endif
internal final class CogLinkedEdgePool {
  // Written out, and `nonisolated`, per the rule at the top of
  // `CogDescriptor.swift`. A synthesized `deinit` on a main-actor-isolated
  // class is main-actor-isolated too, so every deallocation asks the
  // concurrency runtime which executor it is on (`M9-13`).
  nonisolated deinit {}

  /// Creates empty edge storage for one arena context.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  init() {}

  /// Contiguous live and reusable entries.
  ///
  /// The setter stays private so only this owner can grow or replace entries;
  /// infrastructure tests may inspect links through the internal getter.
  private(set) var edges: ContiguousArray<CogPoolEdge> = []

  /// First reusable entry, linked through free entries' `nextDep` field.
  private var freeHead = CogEdgeIndex.none

  /// Number of entries currently linked into graph topology.
  private(set) var liveCount = 0

  /// Number of allocated entry slots, live plus reusable.
  var entryCount: Int { edges.count }

  /// Appends a producer dependency in one consumer's selector-read order.
  ///
  /// `previous` is that consumer's current dependency tail, or `.none` for its
  /// first read. Requiring the tail makes ordered capture O(1) without a second
  /// per-consumer scalar. The same edge becomes the newest subscriber of its
  /// producer so reverse invalidation also stays O(1).
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  func add(
    producer: CogArenaSlot,
    consumer: CogArenaSlot,
    after previous: CogEdgeIndex,
    version: UInt32,
    in arena: CogArenaStorage
  ) -> CogEdgeIndex {
    let producerRow = arena.index(of: producer)
    let consumerRow = arena.index(of: consumer)

    if previous == .none {
      guard arena.deps[consumerRow] == .none else {
        fatalError("Cog tried to append a first edge to a nonempty dependency list.")
      }
    } else {
      let previousRow = liveEntryIndex(previous)
      guard edges[previousRow].sub == consumer.index else {
        fatalError("Cog tried to append after another consumer's dependency edge.")
      }
      guard edges[previousRow].nextDep == .none else {
        fatalError("Cog tried to append after an edge that was not the dependency tail.")
      }
    }

    let index = allocateEntry()
    let nextSubscriber = arena.subs[producerRow]
    edges[entryIndex(index)] = CogPoolEdge(
      dep: producer.index,
      sub: consumer.index,
      prevSub: .none,
      nextSub: nextSubscriber,
      nextDep: .none,
      version: version
    )

    if nextSubscriber != .none {
      edges[liveEntryIndex(nextSubscriber)].prevSub = index
    }
    arena.subs[producerRow] = index

    if previous == .none {
      arena.deps[consumerRow] = index
    } else {
      edges[liveEntryIndex(previous)].nextDep = index
    }

    liveCount += 1
    return index
  }

  /// Removes one arbitrary live edge from both graph lists.
  ///
  /// Reverse unlink is O(1). Finding the predecessor in the consumer's singly
  /// linked dependency list is linear; recapture removes whole trailing
  /// suffixes through ``removeAllDependencies(of:in:)`` or a later cursor API
  /// rather than repeatedly taking this arbitrary-removal path.
  func remove(_ index: CogEdgeIndex, in arena: CogArenaStorage) {
    let row = liveEntryIndex(index)
    let edge = edges[row]
    unlinkSubscriber(index, edge: edge, in: arena)
    unlinkDependency(index, edge: edge, in: arena)
    recycle(index, at: row)
  }

  /// Removes every dependency owned by one live consumer in list order.
  ///
  /// Each entry unlinks from its producer in O(1), then joins the free list.
  /// The method returns the number removed for churn accounting and diagnostics.
  @discardableResult
  func removeAllDependencies(of consumer: CogArenaSlot, in arena: CogArenaStorage) -> Int {
    let consumerRow = arena.index(of: consumer)
    var cursor = arena.deps[consumerRow]
    arena.deps[consumerRow] = .none
    var removed = 0

    while cursor != .none {
      let row = liveEntryIndex(cursor)
      let edge = edges[row]
      guard edge.sub == consumer.index else {
        fatalError("Cog found another consumer's edge in a dependency list.")
      }
      let next = edge.nextDep
      unlinkSubscriber(cursor, edge: edge, in: arena)
      recycle(cursor, at: row)
      removed += 1
      cursor = next
    }
    return removed
  }

  /// Removes the dependency suffix after one preserved consumer prefix.
  ///
  /// `previous` is the last edge reused by the current selector run, or
  /// `.none` when its new dependency list shares no prefix with the old one.
  /// The consumer list is cut once; every abandoned entry then unlinks from
  /// its producer in O(1) and joins the in-entry free list. The preserved
  /// prefix remains in selector read order and becomes the append tail.
  @discardableResult
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  func removeDependencySuffix(
    of consumer: CogArenaSlot,
    after previous: CogEdgeIndex,
    in arena: CogArenaStorage
  ) -> Int {
    let consumerRow = arena.index(of: consumer)
    let firstRemoved: CogEdgeIndex

    if previous == .none {
      firstRemoved = arena.deps[consumerRow]
      arena.deps[consumerRow] = .none
    } else {
      let previousRow = liveEntryIndex(previous)
      guard edges[previousRow].sub == consumer.index else {
        fatalError("Cog tried to preserve another consumer's dependency prefix.")
      }
      firstRemoved = edges[previousRow].nextDep
      edges[previousRow].nextDep = .none
    }

    var cursor = firstRemoved
    var removed = 0
    while cursor != .none {
      let row = liveEntryIndex(cursor)
      let edge = edges[row]
      guard edge.sub == consumer.index else {
        fatalError("Cog found another consumer's edge in a dependency suffix.")
      }
      let next = edge.nextDep
      unlinkSubscriber(cursor, edge: edge, in: arena)
      recycle(cursor, at: row)
      removed += 1
      cursor = next
    }
    return removed
  }

  /// Whether `index` currently names a live linked entry.
  func contains(_ index: CogEdgeIndex) -> Bool {
    guard index.rawValue >= 0 else { return false }
    let row = Int(index.rawValue)
    return row < edges.count && edges[row].isLive
  }

  /// Returns one live entry for an indexed arena graph walk.
  func edge(at index: CogEdgeIndex) -> CogPoolEdge {
    edges[liveEntryIndex(index)]
  }

  /// Refreshes the producer version captured by one reused dependency edge.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  func updateVersion(of index: CogEdgeIndex, to version: UInt32) {
    edges[liveEntryIndex(index)].version = version
  }

  /// Allocates an entry index from the in-entry free list or grows the pool.
  private func allocateEntry() -> CogEdgeIndex {
    if freeHead != .none {
      let reused = freeHead
      freeHead = edges[entryIndex(reused)].nextDep
      return reused
    }

    guard edges.count <= Int(Int32.max) else {
      fatalError("Cog exhausted its Int32 edge-pool index space.")
    }
    let index = CogEdgeIndex(rawValue: Int32(edges.count))
    edges.append(.free(next: .none))
    return index
  }

  /// Unlinks one edge from its producer's doubly linked subscriber list.
  private func unlinkSubscriber(
    _ index: CogEdgeIndex,
    edge: CogPoolEdge,
    in arena: CogArenaStorage
  ) {
    let producerRow = Int(edge.dep)
    guard producerRow >= 0, producerRow < arena.rowCount,
      arena.flags[producerRow].contains(.occupied)
    else {
      fatalError("Cog tried to unlink an edge after its producer slot was released.")
    }

    if edge.prevSub == .none {
      guard arena.subs[producerRow] == index else {
        fatalError("Cog found a broken producer subscriber head.")
      }
      arena.subs[producerRow] = edge.nextSub
    } else {
      let previousRow = liveEntryIndex(edge.prevSub)
      guard edges[previousRow].nextSub == index else {
        fatalError("Cog found a broken previous-subscriber link.")
      }
      edges[previousRow].nextSub = edge.nextSub
    }

    if edge.nextSub != .none {
      let nextRow = liveEntryIndex(edge.nextSub)
      guard edges[nextRow].prevSub == index else {
        fatalError("Cog found a broken next-subscriber link.")
      }
      edges[nextRow].prevSub = edge.prevSub
    }
  }

  /// Unlinks one edge from its consumer's singly linked dependency list.
  private func unlinkDependency(
    _ index: CogEdgeIndex,
    edge: CogPoolEdge,
    in arena: CogArenaStorage
  ) {
    let consumerRow = Int(edge.sub)
    guard consumerRow >= 0, consumerRow < arena.rowCount,
      arena.flags[consumerRow].contains(.occupied)
    else {
      fatalError("Cog tried to unlink an edge after its consumer slot was released.")
    }

    var cursor = arena.deps[consumerRow]
    var previous = CogEdgeIndex.none
    while cursor != .none, cursor != index {
      previous = cursor
      cursor = edges[liveEntryIndex(cursor)].nextDep
    }
    guard cursor == index else {
      fatalError("Cog found an edge missing from its consumer dependency list.")
    }

    if previous == .none {
      arena.deps[consumerRow] = edge.nextDep
    } else {
      edges[liveEntryIndex(previous)].nextDep = edge.nextDep
    }
  }

  /// Clears one unlinked entry and pushes it onto the free list.
  private func recycle(_ index: CogEdgeIndex, at row: Int) {
    edges[row] = .free(next: freeHead)
    freeHead = index
    liveCount -= 1
  }

  /// Converts any allocated edge index to the pool's native array index.
  private func entryIndex(_ index: CogEdgeIndex) -> Int {
    guard index.rawValue >= 0 else {
      fatalError("Cog tried to index the edge pool with its none sentinel.")
    }
    let row = Int(index.rawValue)
    guard row < edges.count else {
      fatalError("Cog tried to use an edge index outside the pool.")
    }
    return row
  }

  /// Resolves a live edge index and rejects free-list entries.
  private func liveEntryIndex(_ index: CogEdgeIndex) -> Int {
    let row = entryIndex(index)
    guard edges[row].isLive else {
      fatalError("Cog tried to use a released edge-pool entry.")
    }
    return row
  }
}
