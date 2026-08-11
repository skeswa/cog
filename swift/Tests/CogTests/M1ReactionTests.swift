import Cog
import CogTesting
import Testing

// Reaction behavior is proved through the public registration, read, and turn
// APIs. Tokens stay alive for the duration of each test so later cancellation
// semantics cannot turn these wake-up tests into lifetime tests by accident.

@MainActor
@Test func `REACT-01 run performs its initial tracking run immediately`() {
  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(1)
  var seen: [Int] = []

  let token = cogs.run { c in
    seen.append(c.get(source))
  }

  #expect(seen == [1])
  _ = token
}

@MainActor
@Test func `REACT-02 changing a dependency wakes the reaction`() {
  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(1)
  var seen: [Int] = []

  let token = cogs.run { c in
    seen.append(c.get(source))
  }

  cogs.commit { w in w[source] = 2 }

  #expect(seen == [1, 2])
  _ = token
}

@MainActor
@Test func `REACT-03 an unrelated turn leaves the reaction quiet`() {
  let cogs = Cogtext.forTesting()
  let observed = ManualCog<Int>(1)
  let unrelated = ManualCog<Int>(10)
  var runs = 0

  let token = cogs.run { c in
    _ = c.get(observed)
    runs += 1
  }

  cogs.commit { w in w[unrelated] = 11 }

  #expect(runs == 1)
  _ = token
}
