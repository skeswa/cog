/// Which per-row prefix array one ephemeral cursor resumes.
private nonisolated enum CogPrefixEdgeList: UInt8, Sendable {
  /// A consumer's ordered producer/version pairs.
  case dependencies

  /// A producer's reverse consumer rows.
  case subscribers
}

/// Position inside one row-owned prefix edge array.
///
/// The owner row makes a cursor self-contained while dependency capture is
/// nested. The list discriminator turns a crossed traversal API into a clear
/// invariant failure instead of reading an unrelated row array by accident.
internal nonisolated struct CogPrefixEdgeCursor: CogArenaEdgeCursor {
  /// Arena row owning the traversed array.
  fileprivate let owner: Int32

  /// Zero-based element offset inside that row's array.
  fileprivate let offset: Int32

  /// Whether the cursor resumes forward or reverse topology.
  fileprivate let list: CogPrefixEdgeList

  /// Universal list terminator; its other fields are deliberately invalid.
  static let none = CogPrefixEdgeCursor(owner: -1, offset: -1, list: .dependencies)
}

/// Compact producer and revision stored in one consumer's dependency array.
private nonisolated struct CogPrefixDependency: Sendable {
  /// Producer arena row.
  let producer: Int32

  /// Producer revision captured by the consumer's last completed selector run.
  var version: UInt32
}

/// Reactively-style edge candidate using arrays owned by each state row.
///
/// A consumer keeps dependencies in selector-read order, so recapture compares
/// and reuses the longest unchanged prefix. A producer keeps a compact reverse
/// array of consumer rows for push invalidation. Dynamic suffix removal edits
/// both directions before appending replacements. No edge object, hash table,
/// or shared pool entry participates in a normal read.
@MainActor
internal final class CogPrefixEdgeStorage: CogArenaEdgeStorageProtocol {
  // Written out, and `nonisolated`, per the rule at the top of
  // `CogDescriptor.swift`. A synthesized `deinit` on a main-actor-isolated
  // class is main-actor-isolated too, so every deallocation asks the
  // concurrency runtime which executor it is on (`M9-13`).
  nonisolated deinit {}

  /// Ordered producer/version pairs by consumer row.
  private var dependencies: ContiguousArray<ContiguousArray<CogPrefixDependency>> = []

  /// Reverse consumer rows by producer row.
  private var subscribers: ContiguousArray<ContiguousArray<Int32>> = []

  /// Number of forward entries currently represented in both directions.
  private(set) var liveCount = 0

  /// High-water live entry count, matching the pool's diagnostic capacity role.
  private(set) var entryCount = 0

  /// Creates edge storage with no row arrays allocated yet.
  init() {}

  /// Returns the first producer in one consumer's dependency array.
  func firstDependency(
    of consumerRow: Int32,
    in arena: CogArenaStorage
  ) -> CogPrefixEdgeCursor {
    let row = liveRow(consumerRow, in: arena)
    ensureRows(through: row)
    guard !dependencies[row].isEmpty else { return .none }
    return CogPrefixEdgeCursor(owner: consumerRow, offset: 0, list: .dependencies)
  }

  /// Returns one dependency and advances within the same consumer array.
  func dependency(
    at cursor: CogPrefixEdgeCursor
  ) -> CogArenaDependency<CogPrefixEdgeCursor> {
    let position = dependencyPosition(cursor)
    let dependency = dependencies[position.owner][position.offset]
    let nextOffset = position.offset + 1
    let next =
      nextOffset < dependencies[position.owner].count
      ? CogPrefixEdgeCursor(
        owner: cursor.owner,
        offset: Int32(nextOffset),
        list: .dependencies
      ) : .none
    return CogArenaDependency(
      producer: dependency.producer,
      consumer: cursor.owner,
      next: next,
      version: dependency.version
    )
  }

  /// Returns the first consumer in one producer's reverse array.
  func firstSubscriber(
    of producerRow: Int32,
    in arena: CogArenaStorage
  ) -> CogPrefixEdgeCursor {
    let row = liveRow(producerRow, in: arena)
    ensureRows(through: row)
    guard !subscribers[row].isEmpty else { return .none }
    return CogPrefixEdgeCursor(owner: producerRow, offset: 0, list: .subscribers)
  }

  /// Returns one consumer and advances within the same producer array.
  func subscriber(at cursor: CogPrefixEdgeCursor) -> CogArenaSubscriber<CogPrefixEdgeCursor> {
    let position = subscriberPosition(cursor)
    let nextOffset = position.offset + 1
    let next =
      nextOffset < subscribers[position.owner].count
      ? CogPrefixEdgeCursor(
        owner: cursor.owner,
        offset: Int32(nextOffset),
        list: .subscribers
      ) : .none
    return CogArenaSubscriber(
      consumer: subscribers[position.owner][position.offset],
      next: next
    )
  }

  /// Appends one producer/version pair and its reverse subscriber entry.
  func add(
    producer: CogArenaSlot,
    consumer: CogArenaSlot,
    after previous: CogPrefixEdgeCursor,
    version: UInt32,
    in arena: CogArenaStorage
  ) -> CogPrefixEdgeCursor {
    let producerRow = arena.index(of: producer)
    let consumerRow = arena.index(of: consumer)
    ensureRows(through: max(producerRow, consumerRow))

    if previous == .none {
      guard dependencies[consumerRow].isEmpty else {
        fatalError("Cog tried to append a first prefix edge to a nonempty dependency array.")
      }
    } else {
      let position = dependencyPosition(previous)
      guard position.owner == consumerRow else {
        fatalError("Cog tried to append after another consumer's prefix edge.")
      }
      guard position.offset == dependencies[consumerRow].count - 1 else {
        fatalError("Cog tried to append after a prefix edge that was not the array tail.")
      }
    }

    dependencies[consumerRow].append(
      CogPrefixDependency(producer: producer.index, version: version)
    )
    subscribers[producerRow].append(consumer.index)
    liveCount += 1
    entryCount = max(entryCount, liveCount)
    return CogPrefixEdgeCursor(
      owner: consumer.index,
      offset: Int32(dependencies[consumerRow].count - 1),
      list: .dependencies
    )
  }

  /// Removes one changed dependency suffix and matching reverse entries.
  @discardableResult
  func removeDependencySuffix(
    of consumer: CogArenaSlot,
    after previous: CogPrefixEdgeCursor,
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
        fatalError("Cog tried to preserve another consumer's prefix dependency.")
      }
      firstRemoved = position.offset + 1
    }

    guard firstRemoved <= dependencies[consumerRow].count else {
      fatalError("Cog tried to remove a prefix dependency suffix past its array end.")
    }
    guard firstRemoved < dependencies[consumerRow].count else { return 0 }

    let removed = dependencies[consumerRow].count - firstRemoved
    for dependency in dependencies[consumerRow][firstRemoved...] {
      let producerRow = liveRow(dependency.producer, in: arena)
      guard let reverse = subscribers[producerRow].lastIndex(of: consumer.index) else {
        fatalError("Cog found a prefix dependency without its reverse subscriber entry.")
      }
      subscribers[producerRow].remove(at: reverse)
    }
    dependencies[consumerRow].removeSubrange(firstRemoved...)
    liveCount -= removed
    return removed
  }

  /// Refreshes the producer revision on one reused dependency prefix entry.
  func updateVersion(of cursor: CogPrefixEdgeCursor, to version: UInt32) {
    let position = dependencyPosition(cursor)
    dependencies[position.owner][position.offset].version = version
  }

  /// Extends both outer row arrays in lockstep through `row`.
  private func ensureRows(through row: Int) {
    guard row >= dependencies.count else { return }
    let missing = row + 1 - dependencies.count
    dependencies.append(contentsOf: repeatElement([], count: missing))
    subscribers.append(contentsOf: repeatElement([], count: missing))
  }

  /// Validates one live arena row named by an edge operation.
  private func liveRow(_ rawRow: Int32, in arena: CogArenaStorage) -> Int {
    guard rawRow >= 0 else {
      fatalError("Cog found a negative row in prefix edge topology.")
    }
    let row = Int(rawRow)
    guard row < arena.rowCount, arena.flags[row].contains(.occupied) else {
      fatalError("Cog found a released row in prefix edge topology.")
    }
    return row
  }

  /// Resolves and validates a dependency cursor's native array indices.
  private func dependencyPosition(_ cursor: CogPrefixEdgeCursor) -> (owner: Int, offset: Int) {
    guard cursor != .none, cursor.list == .dependencies else {
      fatalError("Cog used a non-dependency cursor in a prefix dependency array.")
    }
    guard cursor.owner >= 0, cursor.offset >= 0 else {
      fatalError("Cog found negative coordinates in a prefix dependency cursor.")
    }
    let owner = Int(cursor.owner)
    let offset = Int(cursor.offset)
    guard owner < dependencies.count, offset < dependencies[owner].count else {
      fatalError("Cog found a prefix dependency cursor outside its row array.")
    }
    return (owner, offset)
  }

  /// Resolves and validates a subscriber cursor's native array indices.
  private func subscriberPosition(_ cursor: CogPrefixEdgeCursor) -> (owner: Int, offset: Int) {
    guard cursor != .none, cursor.list == .subscribers else {
      fatalError("Cog used a non-subscriber cursor in a prefix subscriber array.")
    }
    guard cursor.owner >= 0, cursor.offset >= 0 else {
      fatalError("Cog found negative coordinates in a prefix subscriber cursor.")
    }
    let owner = Int(cursor.owner)
    let offset = Int(cursor.offset)
    guard owner < subscribers.count, offset < subscribers[owner].count else {
      fatalError("Cog found a prefix subscriber cursor outside its row array.")
    }
    return (owner, offset)
  }
}
