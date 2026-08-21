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

  cogs.turn { c in c[input] = 2 }
  #expect(cogs.peek(total) == 3)
  #expect(previousValues == [nil, 1])

  cogs.turn { c in c[input] = 3 }
  #expect(cogs.peek(total) == 6)
  #expect(previousValues == [nil, 1, 3])
}

@MainActor
@Test func `READ-04 each key of an automatic box folds with its own previous value`() {
  // `c.curr` belongs to the exact state, so a keyed selector accumulates per
  // key: one key's fold never sees another key's total.
  let cogs = Cogs.forTesting()
  let inputs = ManualCogBox<Int, String>(0)
  let totals = CogBox<Int, String> { c, key in
    (c.curr ?? 0) + c[inputs[key]]
  }

  cogs.turn { c in c[inputs["home"]] = 1 }
  #expect(cogs.peek(totals["home"]) == 1)
  #expect(cogs.peek(totals["work"]) == 0)

  cogs.turn { c in
    c[inputs["home"]] = 2
    c[inputs["work"]] = 10
  }
  #expect(cogs.peek(totals["home"]) == 3)
  #expect(cogs.peek(totals["work"]) == 10)

  cogs.turn { c in c[inputs["work"]] = 5 }
  #expect(cogs.peek(totals["work"]) == 15)
  #expect(cogs.peek(totals["home"]) == 3)
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

  cogs.turn { c in c[trigger] = 1 }
  #expect(cogs.peek(value) == nil)
  #expect(previousStates == ["no previous run", "previous nil"])
}
