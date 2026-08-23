import Testing

@testable import Cog

// Internal proofs for the arena's selected linked edge storage. These tests
// inspect raw links deliberately; later arena integration tests prove graph
// behavior without depending on the pool representation.

@MainActor
@Test func `LinkedEdgePoolInfrastructure appends dependencies in selector read order`() {
  let arena = CogArenaStorage()
  let pool = CogLinkedEdgePool()
  let firstProducer = arena.allocate()
  let secondProducer = arena.allocate()
  let consumer = arena.allocate()

  let first = pool.add(
    producer: firstProducer,
    consumer: consumer,
    after: .none,
    version: 11,
    in: arena
  )
  let second = pool.add(
    producer: secondProducer,
    consumer: consumer,
    after: first,
    version: 12,
    in: arena
  )

  #expect(dependencyChain(of: consumer, in: arena, pool: pool) == [first, second])
  #expect(subscriberChain(of: firstProducer, in: arena, pool: pool) == [first])
  #expect(subscriberChain(of: secondProducer, in: arena, pool: pool) == [second])

  let firstEdge = pool.edges[edgeArrayIndex(first)]
  let secondEdge = pool.edges[edgeArrayIndex(second)]
  #expect(firstEdge.dep == firstProducer.index)
  #expect(firstEdge.sub == consumer.index)
  #expect(firstEdge.nextDep == second)
  #expect(firstEdge.version == 11)
  #expect(secondEdge.dep == secondProducer.index)
  #expect(secondEdge.sub == consumer.index)
  #expect(secondEdge.nextDep == .none)
  #expect(secondEdge.version == 12)
}

@MainActor
@Test func `LinkedEdgePoolInfrastructure doubly links one producer's subscribers`() {
  let arena = CogArenaStorage()
  let pool = CogLinkedEdgePool()
  let producer = arena.allocate()
  let firstConsumer = arena.allocate()
  let secondConsumer = arena.allocate()

  let first = pool.add(
    producer: producer,
    consumer: firstConsumer,
    after: .none,
    version: 1,
    in: arena
  )
  let second = pool.add(
    producer: producer,
    consumer: secondConsumer,
    after: .none,
    version: 1,
    in: arena
  )

  #expect(subscriberChain(of: producer, in: arena, pool: pool) == [second, first])
  #expect(pool.edges[edgeArrayIndex(second)].prevSub == .none)
  #expect(pool.edges[edgeArrayIndex(second)].nextSub == first)
  #expect(pool.edges[edgeArrayIndex(first)].prevSub == second)
  #expect(pool.edges[edgeArrayIndex(first)].nextSub == .none)
}

@MainActor
@Test func `LinkedEdgePoolInfrastructure removes one edge from both lists`() {
  let arena = CogArenaStorage()
  let pool = CogLinkedEdgePool()
  let firstProducer = arena.allocate()
  let middleProducer = arena.allocate()
  let lastProducer = arena.allocate()
  let firstConsumer = arena.allocate()
  let secondConsumer = arena.allocate()

  let first = pool.add(
    producer: firstProducer,
    consumer: firstConsumer,
    after: .none,
    version: 1,
    in: arena
  )
  let middle = pool.add(
    producer: middleProducer,
    consumer: firstConsumer,
    after: first,
    version: 1,
    in: arena
  )
  let last = pool.add(
    producer: lastProducer,
    consumer: firstConsumer,
    after: middle,
    version: 1,
    in: arena
  )
  let sibling = pool.add(
    producer: middleProducer,
    consumer: secondConsumer,
    after: .none,
    version: 1,
    in: arena
  )

  pool.remove(middle, in: arena)

  #expect(dependencyChain(of: firstConsumer, in: arena, pool: pool) == [first, last])
  #expect(dependencyChain(of: secondConsumer, in: arena, pool: pool) == [sibling])
  #expect(subscriberChain(of: middleProducer, in: arena, pool: pool) == [sibling])
  #expect(pool.edges[edgeArrayIndex(first)].nextDep == last)
  #expect(!pool.contains(middle))
  #expect(pool.liveCount == 3)
}

@MainActor
@Test func `LinkedEdgePoolInfrastructure reuses the exact removed entry`() {
  let arena = CogArenaStorage()
  let pool = CogLinkedEdgePool()
  let firstProducer = arena.allocate()
  let secondProducer = arena.allocate()
  let consumer = arena.allocate()

  let removed = pool.add(
    producer: firstProducer,
    consumer: consumer,
    after: .none,
    version: 7,
    in: arena
  )
  pool.remove(removed, in: arena)

  let reused = pool.add(
    producer: secondProducer,
    consumer: consumer,
    after: .none,
    version: 99,
    in: arena
  )

  #expect(reused == removed)
  #expect(pool.entryCount == 1)
  #expect(pool.liveCount == 1)
  #expect(pool.contains(reused))

  let edge = pool.edges[edgeArrayIndex(reused)]
  #expect(edge.dep == secondProducer.index)
  #expect(edge.sub == consumer.index)
  #expect(edge.prevSub == .none)
  #expect(edge.nextSub == .none)
  #expect(edge.nextDep == .none)
  #expect(edge.version == 99)
}

@MainActor
@Test func `LinkedEdgePoolInfrastructure cuts and recycles one dependency suffix`() {
  let arena = CogArenaStorage()
  let pool = CogLinkedEdgePool()
  let firstProducer = arena.allocate()
  let secondProducer = arena.allocate()
  let thirdProducer = arena.allocate()
  let replacementProducer = arena.allocate()
  let consumer = arena.allocate()

  let first = pool.add(
    producer: firstProducer,
    consumer: consumer,
    after: .none,
    version: 1,
    in: arena
  )
  let second = pool.add(
    producer: secondProducer,
    consumer: consumer,
    after: first,
    version: 1,
    in: arena
  )
  let third = pool.add(
    producer: thirdProducer,
    consumer: consumer,
    after: second,
    version: 1,
    in: arena
  )

  #expect(pool.removeDependencySuffix(of: consumer, after: first, in: arena) == 2)
  #expect(dependencyChain(of: consumer, in: arena, pool: pool) == [first])
  #expect(subscriberChain(of: firstProducer, in: arena, pool: pool) == [first])
  #expect(subscriberChain(of: secondProducer, in: arena, pool: pool).isEmpty)
  #expect(subscriberChain(of: thirdProducer, in: arena, pool: pool).isEmpty)
  #expect(!pool.contains(second))
  #expect(!pool.contains(third))

  let replacement = pool.add(
    producer: replacementProducer,
    consumer: consumer,
    after: first,
    version: 2,
    in: arena
  )

  #expect(replacement == third)
  #expect(pool.entryCount == 3)
  #expect(pool.liveCount == 2)
  #expect(dependencyChain(of: consumer, in: arena, pool: pool) == [first, replacement])
}

@MainActor
@Test func `LinkedEdgePoolInfrastructure churn reuses one bounded pool`() {
  let arena = CogArenaStorage()
  let pool = CogLinkedEdgePool()
  let producers = (0..<64).map { _ in arena.allocate() }
  let consumer = arena.allocate()

  for round in 0..<100 {
    var tail = CogEdgeIndex.none
    for producer in producers {
      tail = pool.add(
        producer: producer,
        consumer: consumer,
        after: tail,
        version: UInt32(round),
        in: arena
      )
    }

    #expect(pool.liveCount == producers.count)
    #expect(dependencyChain(of: consumer, in: arena, pool: pool).count == producers.count)
    #expect(pool.removeAllDependencies(of: consumer, in: arena) == producers.count)
    #expect(pool.liveCount == 0)
    #expect(arena.deps[arena.index(of: consumer)] == .none)
    #expect(producers.allSatisfy { arena.subs[arena.index(of: $0)] == .none })
  }

  #expect(pool.entryCount == producers.count)
}

/// Converts one live edge index for direct infrastructure inspection.
private func edgeArrayIndex(_ edge: CogEdgeIndex) -> Int {
  Int(edge.rawValue)
}

/// Follows one consumer's ordered dependency chain without hiding link errors.
@MainActor
private func dependencyChain(
  of consumer: CogArenaSlot,
  in arena: CogArenaStorage,
  pool: CogLinkedEdgePool
) -> [CogEdgeIndex] {
  var result: [CogEdgeIndex] = []
  var cursor = arena.deps[arena.index(of: consumer)]
  while cursor != .none {
    result.append(cursor)
    cursor = pool.edges[edgeArrayIndex(cursor)].nextDep
  }
  return result
}

/// Follows one producer's reverse subscriber chain and checks back-links.
@MainActor
private func subscriberChain(
  of producer: CogArenaSlot,
  in arena: CogArenaStorage,
  pool: CogLinkedEdgePool
) -> [CogEdgeIndex] {
  var result: [CogEdgeIndex] = []
  var previous = CogEdgeIndex.none
  var cursor = arena.subs[arena.index(of: producer)]
  while cursor != .none {
    result.append(cursor)
    let edge = pool.edges[edgeArrayIndex(cursor)]
    #expect(edge.prevSub == previous)
    previous = cursor
    cursor = edge.nextSub
  }
  return result
}
