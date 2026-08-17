import Testing

@testable import Cog

// Internal proofs for the arena row owner added before any public behavior is
// routed through it. Later M6 integration tasks prove that behavior through the
// core selector; these tests pin only allocation and scalar-storage invariants.

@MainActor
@Test func `ArenaStorageInfrastructure allocates dense rows with aligned scalar columns`() {
  let arena = CogArenaStorage()

  let first = arena.allocate()
  let second = arena.allocate()

  #expect(first.index == 0)
  #expect(second.index == 1)
  #expect(first.generation == 0)
  #expect(second.generation == 0)
  #expect(arena.rowCount == 2)
  #expect(arena.liveCount == 2)

  #expect(arena.flags == [.occupied, .occupied])
  #expect(arena.changedAt == [0, 0])
  #expect(arena.checkedAt == [0, 0])
  #expect(arena.deps == [.none, .none])
  #expect(arena.subs == [.none, .none])
  #expect(arena.boundary == [CogArenaStorage.noIndex, CogArenaStorage.noIndex])
  #expect(arena.generation == [0, 0])
}

@MainActor
@Test func `ArenaStorageInfrastructure releases a row and invalidates its exact token`() {
  let arena = CogArenaStorage()
  let slot = arena.allocate()

  #expect(arena.contains(slot))

  arena.release(slot)

  #expect(!arena.contains(slot))
  #expect(arena.liveCount == 0)
  #expect(arena.flags[0] == [])
  #expect(arena.generation[0] == 1)
}

@MainActor
@Test func `ArenaStorageInfrastructure reuses a released row at its next generation`() {
  let arena = CogArenaStorage()
  let first = arena.allocate()
  _ = arena.allocate()

  arena.release(first)
  let reused = arena.allocate()

  #expect(reused.index == first.index)
  #expect(reused.generation == first.generation + 1)
  #expect(!arena.contains(first))
  #expect(arena.contains(reused))
  #expect(arena.rowCount == 2)
  #expect(arena.liveCount == 2)
}

@MainActor
@Test func `ArenaStorageInfrastructure resets every scalar before a row is reused`() {
  let arena = CogArenaStorage()
  let first = arena.allocate()
  let index = arena.index(of: first)

  arena.flags[index] = [.occupied, .dirty, .computing]
  arena.changedAt[index] = 91
  arena.checkedAt[index] = 92
  arena.deps[index] = CogEdgeIndex(rawValue: 13)
  arena.subs[index] = CogEdgeIndex(rawValue: 14)
  arena.boundary[index] = 15

  arena.release(first)
  let reused = arena.allocate()

  #expect(arena.index(of: reused) == index)
  #expect(arena.flags[index] == .occupied)
  #expect(arena.changedAt[index] == 0)
  #expect(arena.checkedAt[index] == 0)
  #expect(arena.deps[index] == .none)
  #expect(arena.subs[index] == .none)
  #expect(arena.boundary[index] == CogArenaStorage.noIndex)
  #expect(arena.generation[index] == reused.generation)
}

@MainActor
@Test func `ArenaStorageInfrastructure keeps scalar rows independent`() {
  let arena = CogArenaStorage()
  let first = arena.allocate()
  let second = arena.allocate()
  let firstIndex = arena.index(of: first)
  let secondIndex = arena.index(of: second)

  arena.flags[firstIndex].insert(.check)
  arena.changedAt[firstIndex] = 7
  arena.checkedAt[firstIndex] = 8
  arena.deps[firstIndex] = CogEdgeIndex(rawValue: 21)
  arena.subs[firstIndex] = CogEdgeIndex(rawValue: 22)
  arena.boundary[firstIndex] = 23

  #expect(arena.flags[secondIndex] == .occupied)
  #expect(arena.changedAt[secondIndex] == 0)
  #expect(arena.checkedAt[secondIndex] == 0)
  #expect(arena.deps[secondIndex] == .none)
  #expect(arena.subs[secondIndex] == .none)
  #expect(arena.boundary[secondIndex] == CogArenaStorage.noIndex)
}

@MainActor
@Test func `ArenaStorageInfrastructure retires a row instead of wrapping its generation`() {
  let arena = CogArenaStorage()
  var current = arena.allocate()

  for _ in 0..<Int(UInt16.max) {
    arena.release(current)
    current = arena.allocate()
  }

  #expect(current.index == 0)
  #expect(current.generation == UInt16.max)

  arena.release(current)
  let afterExhaustion = arena.allocate()

  #expect(!arena.contains(current))
  #expect(afterExhaustion.index == 1)
  #expect(afterExhaustion.generation == 0)
  #expect(arena.rowCount == 2)
  #expect(arena.liveCount == 1)
}
