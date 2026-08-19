/// Which inline candidate list one ephemeral cursor resumes.
private nonisolated enum CogInlineEdgeList: UInt8, Sendable {
  /// A consumer's inline-first ordered producer/version list.
  case dependencies

  /// A producer's reverse consumer array.
  case subscribers
}

/// Position inside one row-owned inline or overflow edge list.
///
/// Offset zero names the inline dependency. Later offsets index the row's
/// overflow array. The owner and list discriminator keep nested capture cursors
/// self-contained and turn crossed traversal APIs into invariant failures.
internal nonisolated struct CogInlineEdgeCursor: CogArenaEdgeCursor {
  /// Arena row owning the traversed list.
  fileprivate let owner: Int32

  /// Logical dependency or subscriber offset.
  fileprivate let offset: Int32

  /// Whether the cursor resumes forward or reverse topology.
  fileprivate let list: CogInlineEdgeList

  /// Universal list terminator; its other fields are deliberately invalid.
  static let none = CogInlineEdgeCursor(owner: -1, offset: -1, list: .dependencies)
}

/// Producer and revision stored for one non-inline dependency.
private nonisolated struct CogInlineOverflowDependency: Sendable {
  /// Producer arena row.
  let producer: Int32

  /// Producer revision captured by the consumer's last completed selector run.
  var version: UInt32
}

/// One consumer row's inline-first dependency representation.
private nonisolated struct CogInlineDependencyRow: Sendable {
  /// Producer row at logical offset zero, or `-1` when the list is empty.
  var producer: Int32 = -1

  /// Captured producer revision for the inline dependency.
  var version: UInt32 = 0

  /// Dependencies after the first, in selector-read order.
  var overflow: ContiguousArray<CogInlineOverflowDependency> = []

  /// Number of dependencies represented by this row.
  var count: Int { producer < 0 ? 0 : overflow.count + 1 }
}

/// Edge candidate that inlines the first parent and spills additional parents.
///
/// Incremental's common-case layout motivates the single inline producer and
/// version pair: a unary derived row needs no dependency-array allocation.
/// Wider rows spill only their ordered suffix to a contiguous array. Producers
/// retain compact reverse consumer arrays for push invalidation. Recapture
/// preserves the longest matching prefix and removes a divergent suffix from
/// both directions before replacements are appended.
@MainActor
internal final class CogInlineEdgeStorage: CogArenaEdgeStorageProtocol {
  // Written out, and `nonisolated`, per the rule at the top of
  // `CogDescriptor.swift`. A synthesized `deinit` on a main-actor-isolated
  // class is main-actor-isolated too, so every deallocation asks the
  // concurrency runtime which executor it is on (`M9-13`).
  nonisolated deinit {}

  /// Inline-first dependency storage by consumer row.
  private var dependencyRows: ContiguousArray<CogInlineDependencyRow> = []

  /// Reverse consumer rows by producer row.
  private var subscribers: ContiguousArray<ContiguousArray<Int32>> = []

  /// Number of forward entries currently represented in both directions.
  private(set) var liveCount = 0

  /// High-water live entry count, matching the other candidates' diagnostic role.
  private(set) var entryCount = 0

  /// Number of current dependencies that did not fit their row's inline cell.
  private(set) var liveOverflowCount = 0

  /// High-water overflow count retained for representation proofs and measurements.
  private(set) var overflowEntryCount = 0

  /// Creates edge storage with no row records allocated yet.
  init() {}

  /// Returns one consumer's inline dependency when it has any parents.
  func firstDependency(
    of consumerRow: Int32,
    in arena: CogArenaStorage
  ) -> CogInlineEdgeCursor {
    let row = liveRow(consumerRow, in: arena)
    ensureRows(through: row)
    guard dependencyRows[row].count > 0 else { return .none }
    return CogInlineEdgeCursor(owner: consumerRow, offset: 0, list: .dependencies)
  }

  /// Returns one inline or overflow dependency and its logical successor.
  func dependency(
    at cursor: CogInlineEdgeCursor
  ) -> CogArenaDependency<CogInlineEdgeCursor> {
    let position = dependencyPosition(cursor)
    let row = dependencyRows[position.owner]
    let producer: Int32
    let version: UInt32
    if position.offset == 0 {
      producer = row.producer
      version = row.version
    } else {
      let overflow = row.overflow[position.offset - 1]
      producer = overflow.producer
      version = overflow.version
    }

    let nextOffset = position.offset + 1
    let next =
      nextOffset < row.count
      ? CogInlineEdgeCursor(
        owner: cursor.owner,
        offset: Int32(nextOffset),
        list: .dependencies
      ) : .none
    return CogArenaDependency(
      producer: producer,
      consumer: cursor.owner,
      next: next,
      version: version
    )
  }

  /// Returns the first consumer in one producer's reverse array.
  func firstSubscriber(
    of producerRow: Int32,
    in arena: CogArenaStorage
  ) -> CogInlineEdgeCursor {
    let row = liveRow(producerRow, in: arena)
    ensureRows(through: row)
    guard !subscribers[row].isEmpty else { return .none }
    return CogInlineEdgeCursor(owner: producerRow, offset: 0, list: .subscribers)
  }

  /// Returns one consumer and advances within the same producer array.
  func subscriber(at cursor: CogInlineEdgeCursor) -> CogArenaSubscriber<CogInlineEdgeCursor> {
    let position = subscriberPosition(cursor)
    let nextOffset = position.offset + 1
    let next =
      nextOffset < subscribers[position.owner].count
      ? CogInlineEdgeCursor(
        owner: cursor.owner,
        offset: Int32(nextOffset),
        list: .subscribers
      ) : .none
    return CogArenaSubscriber(
      consumer: subscribers[position.owner][position.offset],
      next: next
    )
  }

  /// Appends one producer/version pair inline or at the overflow tail.
  func add(
    producer: CogArenaSlot,
    consumer: CogArenaSlot,
    after previous: CogInlineEdgeCursor,
    version: UInt32,
    in arena: CogArenaStorage
  ) -> CogInlineEdgeCursor {
    let producerRow = arena.index(of: producer)
    let consumerRow = arena.index(of: consumer)
    ensureRows(through: max(producerRow, consumerRow))

    let count = dependencyRows[consumerRow].count
    if previous == .none {
      guard count == 0 else {
        fatalError("Cog tried to append an inline first edge to a nonempty dependency row.")
      }
    } else {
      let position = dependencyPosition(previous)
      guard position.owner == consumerRow else {
        fatalError("Cog tried to append after another consumer's inline edge.")
      }
      guard position.offset == count - 1 else {
        fatalError("Cog tried to append after an inline edge that was not the list tail.")
      }
    }

    if count == 0 {
      dependencyRows[consumerRow].producer = producer.index
      dependencyRows[consumerRow].version = version
    } else {
      dependencyRows[consumerRow].overflow.append(
        CogInlineOverflowDependency(producer: producer.index, version: version)
      )
      liveOverflowCount += 1
      overflowEntryCount = max(overflowEntryCount, liveOverflowCount)
    }
    subscribers[producerRow].append(consumer.index)
    liveCount += 1
    entryCount = max(entryCount, liveCount)
    return CogInlineEdgeCursor(
      owner: consumer.index,
      offset: Int32(count),
      list: .dependencies
    )
  }

  /// Removes one changed dependency suffix and its reverse subscriber entries.
  @discardableResult
  func removeDependencySuffix(
    of consumer: CogArenaSlot,
    after previous: CogInlineEdgeCursor,
    in arena: CogArenaStorage
  ) -> Int {
    let consumerRow = arena.index(of: consumer)
    ensureRows(through: consumerRow)
    let firstRemoved: Int
    if previous == .none {
      firstRemoved = 0
    } else {
      let position = dependencyPosition(previous)
      guard position.owner == consumerRow else {
        fatalError("Cog tried to preserve another consumer's inline dependency.")
      }
      firstRemoved = position.offset + 1
    }

    let oldCount = dependencyRows[consumerRow].count
    guard firstRemoved <= oldCount else {
      fatalError("Cog tried to remove an inline dependency suffix past its list end.")
    }
    guard firstRemoved < oldCount else { return 0 }

    for offset in firstRemoved..<oldCount {
      let producer = dependencyProducer(at: offset, consumerRow: consumerRow)
      let producerRow = liveRow(producer, in: arena)
      guard let reverse = subscribers[producerRow].lastIndex(of: consumer.index) else {
        fatalError("Cog found an inline dependency without its reverse subscriber entry.")
      }
      subscribers[producerRow].remove(at: reverse)
    }

    let removed = oldCount - firstRemoved
    let removedOverflow = removed - (firstRemoved == 0 ? 1 : 0)
    if firstRemoved == 0 {
      dependencyRows[consumerRow].producer = -1
      dependencyRows[consumerRow].version = 0
      dependencyRows[consumerRow].overflow.removeAll(keepingCapacity: true)
    } else {
      dependencyRows[consumerRow].overflow.removeSubrange((firstRemoved - 1)...)
    }
    liveCount -= removed
    liveOverflowCount -= removedOverflow
    return removed
  }

  /// Refreshes the producer revision on one reused inline or overflow entry.
  func updateVersion(of cursor: CogInlineEdgeCursor, to version: UInt32) {
    let position = dependencyPosition(cursor)
    if position.offset == 0 {
      dependencyRows[position.owner].version = version
    } else {
      dependencyRows[position.owner].overflow[position.offset - 1].version = version
    }
  }

  /// Extends the forward records and reverse arrays in lockstep through `row`.
  private func ensureRows(through row: Int) {
    guard row >= dependencyRows.count else { return }
    let missing = row + 1 - dependencyRows.count
    dependencyRows.append(contentsOf: repeatElement(CogInlineDependencyRow(), count: missing))
    subscribers.append(contentsOf: repeatElement([], count: missing))
  }

  /// Validates one live arena row named by an edge operation.
  private func liveRow(_ rawRow: Int32, in arena: CogArenaStorage) -> Int {
    guard rawRow >= 0 else {
      fatalError("Cog found a negative row in inline edge topology.")
    }
    let row = Int(rawRow)
    guard row < arena.rowCount, arena.flags[row].contains(.occupied) else {
      fatalError("Cog found a released row in inline edge topology.")
    }
    return row
  }

  /// Resolves and validates a dependency cursor's logical row position.
  private func dependencyPosition(_ cursor: CogInlineEdgeCursor) -> (owner: Int, offset: Int) {
    guard cursor != .none, cursor.list == .dependencies else {
      fatalError("Cog used a non-dependency cursor in an inline dependency row.")
    }
    guard cursor.owner >= 0, cursor.offset >= 0 else {
      fatalError("Cog found negative coordinates in an inline dependency cursor.")
    }
    let owner = Int(cursor.owner)
    let offset = Int(cursor.offset)
    guard owner < dependencyRows.count, offset < dependencyRows[owner].count else {
      fatalError("Cog found an inline dependency cursor outside its row.")
    }
    return (owner, offset)
  }

  /// Resolves and validates a subscriber cursor's native array indices.
  private func subscriberPosition(_ cursor: CogInlineEdgeCursor) -> (owner: Int, offset: Int) {
    guard cursor != .none, cursor.list == .subscribers else {
      fatalError("Cog used a non-subscriber cursor in an inline subscriber array.")
    }
    guard cursor.owner >= 0, cursor.offset >= 0 else {
      fatalError("Cog found negative coordinates in an inline subscriber cursor.")
    }
    let owner = Int(cursor.owner)
    let offset = Int(cursor.offset)
    guard owner < subscribers.count, offset < subscribers[owner].count else {
      fatalError("Cog found an inline subscriber cursor outside its row array.")
    }
    return (owner, offset)
  }

  /// Returns the producer stored at one validated logical dependency offset.
  private func dependencyProducer(at offset: Int, consumerRow: Int) -> Int32 {
    guard offset >= 0, offset < dependencyRows[consumerRow].count else {
      fatalError("Cog tried to read an inline dependency outside its row.")
    }
    if offset == 0 { return dependencyRows[consumerRow].producer }
    return dependencyRows[consumerRow].overflow[offset - 1].producer
  }
}
