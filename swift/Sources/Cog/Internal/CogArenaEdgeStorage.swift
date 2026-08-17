/// Cursor shared by one concrete arena edge representation's graph walks.
///
/// A cursor is ephemeral traversal state, never durable graph identity. Each
/// candidate chooses the smallest value that can resume one of its own lists.
internal nonisolated protocol CogArenaEdgeCursor: Equatable, Sendable {
  /// Universal terminator for dependency and subscriber traversal.
  static var none: Self { get }
}

/// One dependency yielded in a consumer's selector-read order.
internal nonisolated struct CogArenaDependency<Cursor: CogArenaEdgeCursor>: Sendable {
  /// Producer row read by the consumer.
  let producer: Int32

  /// Consumer row that owns this ordered dependency list.
  let consumer: Int32

  /// Cursor for the next dependency, or the representation's terminator.
  let next: Cursor

  /// Producer change revision captured by the consumer's last completed run.
  let version: UInt32
}

/// One subscriber yielded from a producer's reverse edge list.
internal nonisolated struct CogArenaSubscriber<Cursor: CogArenaEdgeCursor>: Sendable {
  /// Consumer row invalidated when the producer changes.
  let consumer: Int32

  /// Cursor for the next subscriber, or the representation's terminator.
  let next: Cursor
}

/// Compile-time contract implemented by every runnable arena edge candidate.
///
/// The arena core is specialized over one conforming class in each build. The
/// protocol supplies a common source-level contract without storing an
/// existential or selecting a candidate in the graph's hot loops.
@MainActor
internal protocol CogArenaEdgeStorageProtocol: AnyObject {
  /// Ephemeral position used to resume this representation's lists.
  associatedtype Cursor: CogArenaEdgeCursor

  /// Creates empty edge storage for one arena context.
  init()

  /// First producer read by `consumerRow`, or ``CogArenaEdgeCursor/none``.
  func firstDependency(of consumerRow: Int32, in arena: CogArenaStorage) -> Cursor

  /// Restores one dependency and the cursor following it.
  func dependency(at cursor: Cursor) -> CogArenaDependency<Cursor>

  /// First consumer subscribed to `producerRow`, or the cursor terminator.
  func firstSubscriber(of producerRow: Int32, in arena: CogArenaStorage) -> Cursor

  /// Restores one subscriber and the cursor following it.
  func subscriber(at cursor: Cursor) -> CogArenaSubscriber<Cursor>

  /// Appends one dependency after the preserved selector-read prefix.
  func add(
    producer: CogArenaSlot,
    consumer: CogArenaSlot,
    after previous: Cursor,
    version: UInt32,
    in arena: CogArenaStorage
  ) -> Cursor

  /// Removes every dependency after `previous` from both graph directions.
  @discardableResult
  func removeDependencySuffix(
    of consumer: CogArenaSlot,
    after previous: Cursor,
    in arena: CogArenaStorage
  ) -> Int

  /// Refreshes the captured producer revision of one reused dependency.
  func updateVersion(of cursor: Cursor, to version: UInt32)
}

extension CogEdgeIndex: CogArenaEdgeCursor {}

extension CogLinkedEdgePool: CogArenaEdgeStorageProtocol {
  /// Returns the arena scalar head of one pool-backed dependency list.
  func firstDependency(of consumerRow: Int32, in arena: CogArenaStorage) -> CogEdgeIndex {
    arena.deps[liveRow(consumerRow, in: arena)]
  }

  /// Erases one shared pool entry into the common dependency traversal shape.
  func dependency(at cursor: CogEdgeIndex) -> CogArenaDependency<CogEdgeIndex> {
    let edge = edge(at: cursor)
    return CogArenaDependency(
      producer: edge.dep,
      consumer: edge.sub,
      next: edge.nextDep,
      version: edge.version
    )
  }

  /// Returns the arena scalar head of one pool-backed subscriber list.
  func firstSubscriber(of producerRow: Int32, in arena: CogArenaStorage) -> CogEdgeIndex {
    arena.subs[liveRow(producerRow, in: arena)]
  }

  /// Erases one shared pool entry into the common subscriber traversal shape.
  func subscriber(at cursor: CogEdgeIndex) -> CogArenaSubscriber<CogEdgeIndex> {
    let edge = edge(at: cursor)
    return CogArenaSubscriber(consumer: edge.sub, next: edge.nextSub)
  }

  /// Validates one raw row before consulting an arena-owned list head.
  private func liveRow(_ rawRow: Int32, in arena: CogArenaStorage) -> Int {
    guard rawRow >= 0 else {
      fatalError("Cog found a negative arena row while entering an edge list.")
    }
    let row = Int(rawRow)
    guard row < arena.rowCount, arena.flags[row].contains(.occupied) else {
      fatalError("Cog entered an edge list for a released arena row.")
    }
    return row
  }
}

#if COG_CORE_ARENA
#if COG_EDGE_POOL
/// Concrete edge storage compiled into this arena build.
internal typealias CogSelectedArenaEdgeStorage = CogLinkedEdgePool
#elseif COG_EDGE_PREFIX
/// Concrete edge storage compiled into this arena build.
internal typealias CogSelectedArenaEdgeStorage = CogPrefixEdgeStorage
#elseif COG_EDGE_INLINE
/// Concrete edge storage compiled into this arena build.
internal typealias CogSelectedArenaEdgeStorage = CogInlineEdgeStorage
#else
#error("Package.swift selected no implemented arena edge storage")
#endif

/// Propagator specialized over this build's concrete edge representation.
internal typealias CogSelectedArenaDirtyPropagation =
  CogArenaDirtyPropagation<CogSelectedArenaEdgeStorage>
#endif
