import Cog
import CogTesting
import Testing

@MainActor
@Test func `READ-04 curr folds each input into a running total`() {
  let cogs = Cogtext.forTesting()
  let input = ManualCog<Int>(1)
  var previousValues: [Int?] = []

  let total = Cog<Int> { c in
    let previous = c.curr
    previousValues.append(previous)
    return (previous ?? 0) + c.get(input)
  }

  #expect(cogs.read(total) == 1)
  #expect(previousValues == [nil])

  cogs.commit { w in w[input] = 2 }
  #expect(cogs.read(total) == 3)
  #expect(previousValues == [nil, 1])

  cogs.commit { w in w[input] = 3 }
  #expect(cogs.read(total) == 6)
  #expect(previousValues == [nil, 1, 3])
}

@MainActor
@Test func `READ-05 an optional result distinguishes no previous run from previous nil`() {
  let cogs = Cogtext.forTesting()
  let trigger = ManualCog<Int>(0)
  var previousStates: [String] = []

  let value = Cog<Int?> { c in
    _ = c.get(trigger)

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

  #expect(cogs.read(value) == nil)
  #expect(previousStates == ["no previous run"])

  cogs.commit { w in w[trigger] = 1 }
  #expect(cogs.read(value) == nil)
  #expect(previousStates == ["no previous run", "previous nil"])
}
