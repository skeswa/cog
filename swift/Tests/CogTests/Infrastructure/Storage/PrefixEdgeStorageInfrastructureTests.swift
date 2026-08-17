import Testing

@testable import Cog

// Internal proofs for the per-state prefix-array candidate. Arena scenario
// tests remain representation-independent; these tests inspect the candidate's
// ordered forward arrays and compact reverse arrays directly.

@MainActor
@Test func `PrefixEdgeStorageInfrastructure preserves ordered prefixes in both directions`() {
  let arena = CogArenaStorage()
  let storage = CogPrefixEdgeStorage()
  let firstProducer = arena.allocate()
  let secondProducer = arena.allocate()
  let firstConsumer = arena.allocate()
  let secondConsumer = arena.allocate()

  let first = storage.add(
    producer: firstProducer,
    consumer: firstConsumer,
    after: .none,
    version: 11,
    in: arena
  )
  _ = storage.add(
    producer: secondProducer,
    consumer: firstConsumer,
    after: first,
    version: 12,
    in: arena
  )
  _ = storage.add(
    producer: firstProducer,
    consumer: secondConsumer,
    after: .none,
    version: 13,
    in: arena
  )

  #expect(
    dependencies(of: firstConsumer, in: arena, storage: storage)
      == [
        PrefixDependency(producer: firstProducer.index, consumer: firstConsumer.index, version: 11),
        PrefixDependency(
          producer: secondProducer.index, consumer: firstConsumer.index, version: 12),
      ]
  )
  #expect(
    subscribers(of: firstProducer, in: arena, storage: storage)
      == [firstConsumer.index, secondConsumer.index]
  )
  #expect(subscribers(of: secondProducer, in: arena, storage: storage) == [firstConsumer.index])
}

@MainActor
@Test func `PrefixEdgeStorageInfrastructure replaces a suffix without growing its high water`() {
  let arena = CogArenaStorage()
  let storage = CogPrefixEdgeStorage()
  let firstProducer = arena.allocate()
  let abandonedProducer = arena.allocate()
  let replacementProducer = arena.allocate()
  let consumer = arena.allocate()

  let preserved = storage.add(
    producer: firstProducer,
    consumer: consumer,
    after: .none,
    version: 1,
    in: arena
  )
  _ = storage.add(
    producer: abandonedProducer,
    consumer: consumer,
    after: preserved,
    version: 1,
    in: arena
  )

  #expect(storage.removeDependencySuffix(of: consumer, after: preserved, in: arena) == 1)
  #expect(subscribers(of: abandonedProducer, in: arena, storage: storage).isEmpty)

  _ = storage.add(
    producer: replacementProducer,
    consumer: consumer,
    after: preserved,
    version: 2,
    in: arena
  )

  #expect(storage.entryCount == 2)
  #expect(storage.liveCount == 2)
  #expect(
    dependencies(of: consumer, in: arena, storage: storage)
      == [
        PrefixDependency(producer: firstProducer.index, consumer: consumer.index, version: 1),
        PrefixDependency(producer: replacementProducer.index, consumer: consumer.index, version: 2),
      ]
  )
}

@MainActor
@Test func `PrefixEdgeStorageInfrastructure removes one repeated producer occurrence`() {
  let arena = CogArenaStorage()
  let storage = CogPrefixEdgeStorage()
  let producer = arena.allocate()
  let consumer = arena.allocate()

  let preserved = storage.add(
    producer: producer,
    consumer: consumer,
    after: .none,
    version: 1,
    in: arena
  )
  _ = storage.add(
    producer: producer,
    consumer: consumer,
    after: preserved,
    version: 2,
    in: arena
  )

  #expect(storage.removeDependencySuffix(of: consumer, after: preserved, in: arena) == 1)
  #expect(subscribers(of: producer, in: arena, storage: storage) == [consumer.index])
  #expect(storage.liveCount == 1)
}

/// Candidate-neutral dependency fields used for exact traversal assertions.
private struct PrefixDependency: Equatable {
  /// Producer arena row.
  let producer: Int32

  /// Consumer arena row.
  let consumer: Int32

  /// Captured producer revision.
  let version: UInt32
}

/// Traverses one consumer's ordered prefix array through the shared seam.
@MainActor
private func dependencies(
  of consumer: CogArenaSlot,
  in arena: CogArenaStorage,
  storage: CogPrefixEdgeStorage
) -> [PrefixDependency] {
  var result: [PrefixDependency] = []
  var cursor = storage.firstDependency(of: consumer.index, in: arena)
  while cursor != .none {
    let dependency = storage.dependency(at: cursor)
    result.append(
      PrefixDependency(
        producer: dependency.producer,
        consumer: dependency.consumer,
        version: dependency.version
      )
    )
    cursor = dependency.next
  }
  return result
}

/// Traverses one producer's compact reverse array through the shared seam.
@MainActor
private func subscribers(
  of producer: CogArenaSlot,
  in arena: CogArenaStorage,
  storage: CogPrefixEdgeStorage
) -> [Int32] {
  var result: [Int32] = []
  var cursor = storage.firstSubscriber(of: producer.index, in: arena)
  while cursor != .none {
    let subscriber = storage.subscriber(at: cursor)
    result.append(subscriber.consumer)
    cursor = subscriber.next
  }
  return result
}
