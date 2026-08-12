import Cog
import CogTesting
import Testing

// Equality behavior is observable through ordinary reads and selector-owned
// run counts. Nothing here reaches into a descriptor, a state, or settle state,
// so these scenarios remain valid across the M6 core swap.

@MainActor
@Test func `TURN-09 an equal source write does not recompute a derived cog`() {
  var runs = 0

  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(1)
  let doubled = Cog<Int> { c in
    runs += 1
    return c.get(source) * 2
  }

  #expect(cogs.read(doubled) == 2)
  #expect(runs == 1)

  cogs.commit { w in w[source] = 1 }

  #expect(cogs.read(doubled) == 2)
  #expect(runs == 1)
}

@MainActor
@Test func `TURN-09 an equal keyed write uses the box equality rule`() {
  var runs = 0

  let cogs = Cogtext.forTesting()
  let sources = ManualCogBox<Int, String> { key in key.count }
  let doubled = Cog<Int> { c in
    runs += 1
    return c.get(sources["one"]) * 2
  }

  #expect(cogs.read(doubled) == 6)

  cogs.commit { w in w[sources["one"]] = 3 }

  #expect(cogs.read(doubled) == 6)
  #expect(runs == 1)
}

@MainActor
@Test func `TURN-10 changing and reverting in one commit is no change`() {
  var runs = 0

  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(4)
  let squared = Cog<Int> { c in
    runs += 1
    let value = c.get(source)
    return value * value
  }

  #expect(cogs.read(squared) == 16)

  cogs.commit { w in
    w[source] = 5
    #expect(w[source] == 5)

    w[source] = 4
    #expect(w[source] == 4)
  }

  #expect(cogs.read(source) == 4)
  #expect(cogs.read(squared) == 16)
  #expect(runs == 1)
}

@MainActor
@Test func `TURN-11 a custom equals closure decides whether a source changed`() {
  struct Reading {
    let sample: Int
    let note: String
  }

  var runs = 0

  let cogs = Cogtext.forTesting()
  let source = ManualCog<Reading>(
    Reading(sample: 7, note: "first"),
    equals: { old, new in old.sample == new.sample }
  )
  let note = Cog<String> { c in
    runs += 1
    return c.get(source).note
  }

  #expect(cogs.read(note) == "first")

  cogs.commit { w in
    w[source] = Reading(sample: 7, note: "equal by the custom rule")
  }

  #expect(cogs.read(note) == "first")
  #expect(runs == 1)

  cogs.commit { w in
    w[source] = Reading(sample: 8, note: "changed by the custom rule")
  }

  #expect(cogs.read(note) == "changed by the custom rule")
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

  let cogs = Cogtext.forTesting()
  let sources = ManualCogBox<Reading, String>(
    { key in Reading(sample: key.count, note: key) },
    equals: { old, new in old.sample == new.sample }
  )
  let first = Cog<String> { c in
    firstRuns += 1
    return c.get(sources["one"]).note
  }
  let second = Cog<String> { c in
    secondRuns += 1
    return c.get(sources["four"]).note
  }

  #expect(cogs.read(first) == "one")
  #expect(cogs.read(second) == "four")

  cogs.commit { w in
    w[sources["one"]] = Reading(sample: 3, note: "equal")
    w[sources["four"]] = Reading(sample: 5, note: "changed")
  }

  #expect(cogs.read(first) == "one")
  #expect(cogs.read(second) == "changed")
  #expect(firstRuns == 1)
  #expect(secondRuns == 2)
}

@MainActor
@Test func `TURN-12 a non-Equatable source treats every write as changed`() {
  struct Reading {
    let value: Int
  }

  var runs = 0

  let cogs = Cogtext.forTesting()
  let source = ManualCog<Reading>(Reading(value: 3))
  let value = Cog<Int> { c in
    runs += 1
    return c.get(source).value
  }

  #expect(cogs.read(value) == 3)
  #expect(runs == 1)

  cogs.commit { w in w[source] = Reading(value: 3) }

  #expect(cogs.read(value) == 3)
  #expect(runs == 2)
}
