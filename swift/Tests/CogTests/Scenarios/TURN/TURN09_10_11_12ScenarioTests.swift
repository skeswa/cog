import Cog
import CogTesting
import Testing

// Selector-owned counters make equality behavior visible through public reads.

@MainActor
@Test func `TURN-09 an equal source write does not recompute a derived cog`() {
  var runs = 0

  let cogs = Cogs.forTesting()
  let source = ManualCog<Int>(1)
  let doubled = Cog<Int> { c in
    runs += 1
    return c[source] * 2
  }

  #expect(cogs.peek(doubled) == 2)
  #expect(runs == 1)

  cogs.commit { c in c[source] = 1 }

  #expect(cogs.peek(doubled) == 2)
  #expect(runs == 1)
}

@MainActor
@Test func `TURN-09 an equal keyed write uses the box equality rule`() {
  var runs = 0

  let cogs = Cogs.forTesting()
  let sources = ManualCogBox<Int, String> { key in key.count }
  let doubled = Cog<Int> { c in
    runs += 1
    return c[sources["one"]] * 2
  }

  #expect(cogs.peek(doubled) == 6)

  cogs.commit { c in c[sources["one"]] = 3 }

  #expect(cogs.peek(doubled) == 6)
  #expect(runs == 1)
}

@MainActor
@Test func `TURN-10 changing and reverting in one commit is no change`() {
  var runs = 0

  let cogs = Cogs.forTesting()
  let source = ManualCog<Int>(4)
  let squared = Cog<Int> { c in
    runs += 1
    let value = c[source]
    return value * value
  }

  #expect(cogs.peek(squared) == 16)

  cogs.commit { c in
    c[source] = 5
    #expect(c[source] == 5)

    c[source] = 4
    #expect(c[source] == 4)
  }

  #expect(cogs.peek(source) == 4)
  #expect(cogs.peek(squared) == 16)
  #expect(runs == 1)
}

@MainActor
@Test func `TURN-11 a custom equals closure decides whether a source changed`() {
  struct Reading {
    let sample: Int
    let note: String
  }

  var runs = 0

  let cogs = Cogs.forTesting()
  let source = ManualCog<Reading>(
    Reading(sample: 7, note: "first"),
    equals: { old, new in old.sample == new.sample }
  )
  let note = Cog<String> { c in
    runs += 1
    return c[source].note
  }

  #expect(cogs.peek(note) == "first")

  cogs.commit { c in
    c[source] = Reading(sample: 7, note: "equal by the custom rule")
  }

  #expect(cogs.peek(note) == "first")
  #expect(runs == 1)

  cogs.commit { c in
    c[source] = Reading(sample: 8, note: "changed by the custom rule")
  }

  #expect(cogs.peek(note) == "changed by the custom rule")
  #expect(runs == 2)
}

@MainActor
@Test func `TURN-11 a box shares its custom equality rule across keys`() {
  struct Reading {
    let sample: Int
    let note: String
  }

  var firstRuns = 0
  var secondRuns = 0

  let cogs = Cogs.forTesting()
  let sources = ManualCogBox<Reading, String>(
    { key in Reading(sample: key.count, note: key) },
    equals: { old, new in old.sample == new.sample }
  )
  let first = Cog<String> { c in
    firstRuns += 1
    return c[sources["one"]].note
  }
  let second = Cog<String> { c in
    secondRuns += 1
    return c[sources["four"]].note
  }

  #expect(cogs.peek(first) == "one")
  #expect(cogs.peek(second) == "four")

  cogs.commit { c in
    c[sources["one"]] = Reading(sample: 3, note: "equal")
    c[sources["four"]] = Reading(sample: 5, note: "changed")
  }

  #expect(cogs.peek(first) == "one")
  #expect(cogs.peek(second) == "changed")
  #expect(firstRuns == 1)
  #expect(secondRuns == 2)
}

@MainActor
@Test func `TURN-12 a non-Equatable source treats every write as changed`() {
  struct Reading {
    let value: Int
  }

  var runs = 0

  let cogs = Cogs.forTesting()
  let source = ManualCog<Reading>(Reading(value: 3))
  let value = Cog<Int> { c in
    runs += 1
    return c[source].value
  }

  #expect(cogs.peek(value) == 3)
  #expect(runs == 1)

  cogs.commit { c in c[source] = Reading(value: 3) }

  #expect(cogs.peek(value) == 3)
  #expect(runs == 2)
}
