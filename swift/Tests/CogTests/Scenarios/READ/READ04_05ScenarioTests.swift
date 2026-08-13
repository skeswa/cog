import Cog
import CogTesting
import Testing

@MainActor
@Test func `READ-04 curr folds each input into a running total`() {
  let cogs = Cogs.forTesting()
  let input = ManualCog<Int>(1)
  var previousValues: [Int?] = []

  let total = Cog<Int> { c in
    let previous = c.curr
    previousValues.append(previous)
    return (previous ?? 0) + c[input]
  }

  #expect(cogs.peek(total) == 1)
  #expect(previousValues == [nil])

  cogs.commit { c in c[input] = 2 }
  #expect(cogs.peek(total) == 3)
  #expect(previousValues == [nil, 1])

  cogs.commit { c in c[input] = 3 }
  #expect(cogs.peek(total) == 6)
  #expect(previousValues == [nil, 1, 3])
}

@MainActor
@Test func `READ-05 an optional result distinguishes no previous run from previous nil`() {
  let cogs = Cogs.forTesting()
  let trigger = ManualCog<Int>(0)
  var previousStates: [String] = []

  let value = Cog<Int?> { c in
    _ = c[trigger]

    switch c.curr {
    case .none:
      previousStates.append("no previous run")
    case .some(.none):
      previousStates.append("previous nil")
    case .some(.some(let previous)):
      previousStates.append("previous \(previous)")
    }

    return nil
  }

  #expect(cogs.peek(value) == nil)
  #expect(previousStates == ["no previous run"])

  cogs.commit { c in c[trigger] = 1 }
  #expect(cogs.peek(value) == nil)
  #expect(previousStates == ["no previous run", "previous nil"])
}
