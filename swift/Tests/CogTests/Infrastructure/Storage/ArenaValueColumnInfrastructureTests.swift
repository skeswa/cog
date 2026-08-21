import Testing

@testable import Cog

// Internal proofs for descriptor-owned typed value storage. These tests keep
// the column concrete at every call site and inspect behavior rather than
// exposing its optional-backed representation.

@MainActor
@Test func `ArenaValueColumnInfrastructure reads concrete values from sparse arena rows`() {
  let arena = CogArenaStorage()
  let integers = CogArenaValueColumn<Int>(in: arena, equals: ==)
  let strings = CogArenaValueColumn<String>(in: arena, equals: ==)
  let firstInteger = arena.allocate()
  let string = arena.allocate()
  let secondInteger = arena.allocate()

  integers.insert(41, at: firstInteger)
  strings.insert("typed", at: string)
  integers.insert(43, at: secondInteger)

  #expect(integers.current(at: firstInteger) == 41)
  #expect(strings.current(at: string) == "typed")
  #expect(integers.current(at: secondInteger) == 43)
  #expect(integers.contains(firstInteger))
  #expect(!integers.contains(string))
  #expect(strings.contains(string))
}

@MainActor
@Test func `ArenaValueColumnInfrastructure keeps staged writes behind the turn boundary`() {
  let arena = CogArenaStorage()
  let column = CogArenaValueColumn<Int?>(in: arena, equals: ==)
  let slot = arena.allocate()
  column.insert(7, at: slot)

  column.stage(nil, at: slot)

  #expect(column.current(at: slot) == 7)
  #expect(column.writerValue(at: slot) == nil)
  #expect(column.hasPendingValue(at: slot))
  #expect(column.publish(at: slot))
  #expect(column.current(at: slot) == nil)
  #expect(!column.hasPendingValue(at: slot))
}

@MainActor
@Test func `ArenaValueColumnInfrastructure publishes only a descriptor level change`() {
  let arena = CogArenaStorage()
  var comparisons: [(String, String)] = []
  let column = CogArenaValueColumn<String>(
    in: arena,
    equals: { oldValue, newValue in
      comparisons.append((oldValue, newValue))
      return oldValue.lowercased() == newValue.lowercased()
    }
  )
  let slot = arena.allocate()
  column.insert("Cog", at: slot)

  column.stage("COG", at: slot)
  #expect(!column.publish(at: slot))
  #expect(column.current(at: slot) == "Cog")
  #expect(column.writerValue(at: slot) == "Cog")
  #expect(!column.hasPendingValue(at: slot))

  column.stage("Cogs", at: slot)
  #expect(column.publish(at: slot))
  #expect(column.current(at: slot) == "Cogs")
  #expect(comparisons.map { [$0.0, $0.1] } == [["Cog", "COG"], ["Cog", "Cogs"]])
}

@MainActor
@Test func `ArenaValueColumnInfrastructure removes current and pending values before slot reuse`() {
  let arena = CogArenaStorage()
  let column = CogArenaValueColumn<ColumnPayload>(in: arena, equals: ===)
  let firstSlot = arena.allocate()
  weak var oldCurrent: ColumnPayload?
  weak var oldPending: ColumnPayload?

  do {
    let current = ColumnPayload(1)
    let pending = ColumnPayload(2)
    oldCurrent = current
    oldPending = pending
    column.insert(current, at: firstSlot)
    column.stage(pending, at: firstSlot)
  }

  #expect(oldCurrent != nil)
  #expect(oldPending != nil)
  column.remove(at: firstSlot)
  #expect(!column.contains(firstSlot))
  #expect(oldCurrent == nil)
  #expect(oldPending == nil)

  arena.release(firstSlot)
  let reusedSlot = arena.allocate()
  let replacement = ColumnPayload(3)
  column.insert(replacement, at: reusedSlot)

  #expect(reusedSlot.index == firstSlot.index)
  #expect(reusedSlot.generation != firstSlot.generation)
  #expect(column.current(at: reusedSlot) === replacement)
  #expect(column.writerValue(at: reusedSlot) === replacement)
  #expect(!column.hasPendingValue(at: reusedSlot))
}

/// Reference payload that proves removal releases both optional-backed cells.
private final class ColumnPayload {
  /// Distinguishes instances when a failed expectation prints them.
  let value: Int

  /// Creates one retained test payload.
  init(_ value: Int) {
    self.value = value
  }
}
