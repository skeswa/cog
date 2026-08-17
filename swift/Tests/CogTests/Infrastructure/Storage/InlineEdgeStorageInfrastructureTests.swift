import Testing

@testable import Cog

// Internal proofs for the inline-plus-overflow candidate. Arena scenario tests
// remain representation-independent; these tests make the first-parent layout
// and ordered spill behavior explicit.

@MainActor
@Test func `InlineEdgeStorageInfrastructure keeps a unary parent out of overflow`() {
  let arena = CogArenaStorage()
  let storage = CogInlineEdgeStorage()
  let producer = arena.allocate()
  let consumer = arena.allocate()

  _ = storage.add(
    producer: producer,
    consumer: consumer,
    after: .none,
    version: 11,
    in: arena
  )

  #expect(storage.liveCount == 1)
  #expect(storage.entryCount == 1)
  #expect(storage.liveOverflowCount == 0)
  #expect(storage.overflowEntryCount == 0)
  #expect(
    inlineDependencies(of: consumer, in: arena, storage: storage)
      == [
        InlineDependency(producer: producer.index, consumer: consumer.index, version: 11)
      ]
  )
  #expect(inlineSubscribers(of: producer, in: arena, storage: storage) == [consumer.index])
}

@MainActor
@Test func `InlineEdgeStorageInfrastructure spills only the ordered suffix`() {
  let arena = CogArenaStorage()
  let storage = CogInlineEdgeStorage()
  let firstProducer = arena.allocate()
  let secondProducer = arena.allocate()
  let thirdProducer = arena.allocate()
  let consumer = arena.allocate()

  let first = storage.add(
    producer: firstProducer,
    consumer: consumer,
    after: .none,
    version: 1,
    in: arena
  )
  let second = storage.add(
    producer: secondProducer,
    consumer: consumer,
    after: first,
    version: 2,
    in: arena
  )
  _ = storage.add(
    producer: thirdProducer,
    consumer: consumer,
    after: second,
    version: 3,
    in: arena
  )

  #expect(storage.liveOverflowCount == 2)
  #expect(storage.overflowEntryCount == 2)
  #expect(
    inlineDependencies(of: consumer, in: arena, storage: storage).map(\.producer)
      == [firstProducer.index, secondProducer.index, thirdProducer.index]
  )
}

@MainActor
@Test func `InlineEdgeStorageInfrastructure replaces overflow without moving the first parent`() {
  let arena = CogArenaStorage()
  let storage = CogInlineEdgeStorage()
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
  #expect(storage.liveOverflowCount == 0)
  #expect(inlineSubscribers(of: abandonedProducer, in: arena, storage: storage).isEmpty)

  _ = storage.add(
    producer: replacementProducer,
    consumer: consumer,
    after: preserved,
    version: 2,
    in: arena
  )

  #expect(storage.entryCount == 2)
  #expect(storage.overflowEntryCount == 1)
  #expect(
    inlineDependencies(of: consumer, in: arena, storage: storage)
      == [
        InlineDependency(producer: firstProducer.index, consumer: consumer.index, version: 1),
        InlineDependency(
          producer: replacementProducer.index,
          consumer: consumer.index,
          version: 2
        ),
      ]
  )
}

@MainActor
@Test func `InlineEdgeStorageInfrastructure clears inline and overflow topology together`() {
  let arena = CogArenaStorage()
  let storage = CogInlineEdgeStorage()
  let producer = arena.allocate()
  let consumer = arena.allocate()

  let first = storage.add(
    producer: producer,
    consumer: consumer,
    after: .none,
    version: 1,
    in: arena
  )
  _ = storage.add(
    producer: producer,
    consumer: consumer,
    after: first,
    version: 2,
    in: arena
  )

  #expect(storage.removeDependencySuffix(of: consumer, after: .none, in: arena) == 2)
  #expect(inlineDependencies(of: consumer, in: arena, storage: storage).isEmpty)
  #expect(inlineSubscribers(of: producer, in: arena, storage: storage).isEmpty)
  #expect(storage.liveCount == 0)
  #expect(storage.liveOverflowCount == 0)
}

/// Candidate-neutral dependency fields used for exact traversal assertions.
private struct InlineDependency: Equatable {
  /// Producer arena row.
  let producer: Int32

  /// Consumer arena row.
  let consumer: Int32

  /// Captured producer revision.
  let version: UInt32
}

/// Traverses one consumer's inline-first dependency list through the shared seam.
@MainActor
private func inlineDependencies(
  of consumer: CogArenaSlot,
  in arena: CogArenaStorage,
  storage: CogInlineEdgeStorage
) -> [InlineDependency] {
  var result: [InlineDependency] = []
  var cursor = storage.firstDependency(of: consumer.index, in: arena)
  while cursor != .none {
    let dependency = storage.dependency(at: cursor)
    result.append(
      InlineDependency(
        producer: dependency.producer,
        consumer: dependency.consumer,
        version: dependency.version
      )
    )
    cursor = dependency.next
  }
  return result
}

/// Traverses one producer's reverse subscribers through the shared seam.
@MainActor
private func inlineSubscribers(
  of producer: CogArenaSlot,
  in arena: CogArenaStorage,
  storage: CogInlineEdgeStorage
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
