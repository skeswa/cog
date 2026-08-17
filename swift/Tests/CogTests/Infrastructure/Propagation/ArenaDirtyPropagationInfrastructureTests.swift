import Testing

@testable import Cog

// Internal proofs for the first arena turn slice. They connect scalar rows,
// typed values, and pool edges directly so failures identify propagation
// machinery before the public runtime switches cores.

@MainActor
@Test func `ArenaDirtyPropagationInfrastructure commits a source then pushes dirty and check`() {
  let arena = CogArenaStorage()
  let edges = CogLinkedEdgePool()
  let propagation = CogArenaDirtyPropagation(arena: arena, edges: edges)
  let values = CogArenaValueColumn<Int>(in: arena, equals: ==)
  let source = arena.allocate()
  let directConsumer = arena.allocate()
  let downstreamConsumer = arena.allocate()
  values.insert(1, at: source)

  _ = edges.add(
    producer: source,
    consumer: directConsumer,
    after: .none,
    version: 0,
    in: arena
  )
  _ = edges.add(
    producer: directConsumer,
    consumer: downstreamConsumer,
    after: .none,
    version: 0,
    in: arena
  )

  values.stage(2, at: source)

  #expect(values.current(at: source) == 1)
  #expect(values.writerValue(at: source) == 2)
  #expect(arena.flags[arena.index(of: directConsumer)] == .occupied)
  #expect(arena.flags[arena.index(of: downstreamConsumer)] == .occupied)

  #expect(values.commitSource(at: source, revision: 7, propagatingWith: propagation))

  let sourceRow = arena.index(of: source)
  #expect(values.current(at: source) == 2)
  #expect(!values.hasPendingValue(at: source))
  #expect(arena.changedAt[sourceRow] == 7)
  #expect(arena.checkedAt[sourceRow] == 7)
  #expect(arena.flags[sourceRow] == .occupied)
  #expect(
    arena.flags[arena.index(of: directConsumer)] == [.occupied, .dirty]
  )
  #expect(
    arena.flags[arena.index(of: downstreamConsumer)] == [.occupied, .check]
  )
}

@MainActor
@Test func `ArenaDirtyPropagationInfrastructure ignores a final equal staged value`() {
  let arena = CogArenaStorage()
  let edges = CogLinkedEdgePool()
  let propagation = CogArenaDirtyPropagation(arena: arena, edges: edges)
  let values = CogArenaValueColumn<Int>(in: arena, equals: ==)
  let source = arena.allocate()
  let consumer = arena.allocate()
  values.insert(10, at: source)
  _ = edges.add(
    producer: source,
    consumer: consumer,
    after: .none,
    version: 0,
    in: arena
  )

  values.stage(11, at: source)
  values.stage(10, at: source)

  #expect(!values.commitSource(at: source, revision: 1, propagatingWith: propagation))
  #expect(values.current(at: source) == 10)
  #expect(!values.hasPendingValue(at: source))
  #expect(arena.changedAt[arena.index(of: source)] == 0)
  #expect(arena.checkedAt[arena.index(of: source)] == 0)
  #expect(arena.flags[arena.index(of: consumer)] == .occupied)
}

@MainActor
@Test func `ArenaDirtyPropagationInfrastructure preserves stronger marks across a diamond`() {
  let arena = CogArenaStorage()
  let edges = CogLinkedEdgePool()
  let propagation = CogArenaDirtyPropagation(arena: arena, edges: edges)
  let source = arena.allocate()
  let left = arena.allocate()
  let right = arena.allocate()
  let leaf = arena.allocate()
  let belowLeaf = arena.allocate()

  _ = edges.add(producer: source, consumer: left, after: .none, version: 0, in: arena)
  _ = edges.add(producer: source, consumer: right, after: .none, version: 0, in: arena)
  let firstLeafDependency = edges.add(
    producer: left,
    consumer: leaf,
    after: .none,
    version: 0,
    in: arena
  )
  let secondLeafDependency = edges.add(
    producer: right,
    consumer: leaf,
    after: firstLeafDependency,
    version: 0,
    in: arena
  )
  _ = edges.add(
    producer: source,
    consumer: leaf,
    after: secondLeafDependency,
    version: 0,
    in: arena
  )
  _ = edges.add(
    producer: leaf,
    consumer: belowLeaf,
    after: .none,
    version: 0,
    in: arena
  )

  propagation.invalidateSubscribers(of: source)

  #expect(arena.flags[arena.index(of: left)] == [.occupied, .dirty])
  #expect(arena.flags[arena.index(of: right)] == [.occupied, .dirty])
  #expect(arena.flags[arena.index(of: leaf)] == [.occupied, .dirty])
  #expect(arena.flags[arena.index(of: belowLeaf)] == [.occupied, .check])
}

@MainActor
@Test func `ArenaDirtyPropagationInfrastructure reuses its stack across broad waves`() {
  let arena = CogArenaStorage()
  let edges = CogLinkedEdgePool()
  let propagation = CogArenaDirtyPropagation(arena: arena, edges: edges)
  let source = arena.allocate()
  let consumers = (0..<512).map { _ in arena.allocate() }

  for consumer in consumers {
    _ = edges.add(
      producer: source,
      consumer: consumer,
      after: .none,
      version: 0,
      in: arena
    )
  }

  propagation.invalidateSubscribers(of: source)
  let firstCapacity = propagation.stackCapacity
  #expect(propagation.stackCount == 0)
  #expect(firstCapacity >= consumers.count)
  #expect(consumers.allSatisfy { arena.flags[arena.index(of: $0)].contains(.dirty) })

  for consumer in consumers {
    arena.flags[arena.index(of: consumer)] = .occupied
  }
  propagation.invalidateSubscribers(of: source)

  #expect(propagation.stackCount == 0)
  #expect(propagation.stackCapacity == firstCapacity)
}

@MainActor
@Test func `ArenaDirtyPropagationInfrastructure walks a deep chain without recursion`() {
  let arena = CogArenaStorage()
  let edges = CogLinkedEdgePool()
  let propagation = CogArenaDirtyPropagation(arena: arena, edges: edges)
  let slots = (0..<4_096).map { _ in arena.allocate() }

  for index in 1..<slots.count {
    _ = edges.add(
      producer: slots[index - 1],
      consumer: slots[index],
      after: .none,
      version: 0,
      in: arena
    )
  }

  propagation.invalidateSubscribers(of: slots[0])

  #expect(arena.flags[arena.index(of: slots[1])] == [.occupied, .dirty])
  #expect(arena.flags[arena.index(of: slots.last!)] == [.occupied, .check])
  #expect(propagation.stackCount == 0)
}
