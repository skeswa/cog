#if DEBUG

import Cog
import CogTesting
import Testing

// Seed behavior is proved through the public debug API, ordinary reads, and
// selector-owned counters. Nothing observes turns, reactions, history, graph
// storage, or settle flags; those belong to later seed tasks.

@MainActor
@Test func `SEED-01 the next read returns the seeded source value`() {
  let cogs = Cogs.forTesting()
  let source = ManualCog<Int>(1)

  cogs.seed(source, to: 7)

  #expect(cogs.peek(source) == 7)
}

@MainActor
@Test func `SEED-03 seed dirties a transitive derived chain`() {
  var middleRuns = 0
  var rootRuns = 0

  let cogs = Cogs.forTesting()
  let source = ManualCog<Int>(2)
  let middle = Cog<Int> { c in
    middleRuns += 1
    return c[source] + 1
  }
  let root = Cog<Int> { c in
    rootRuns += 1
    return c[middle] * 2
  }

  #expect(cogs.peek(root) == 6)
  #expect(middleRuns == 1)
  #expect(rootRuns == 1)

  cogs.seed(source, to: 5)

  // Seed marks possible work but does not compute it eagerly.
  #expect(middleRuns == 1)
  #expect(rootRuns == 1)

  #expect(cogs.peek(root) == 12)
  #expect(middleRuns == 2)
  #expect(rootRuns == 2)

  // The settled result is cached like any other derived value.
  #expect(cogs.peek(root) == 12)
  #expect(middleRuns == 2)
  #expect(rootRuns == 2)
}

@MainActor
@Test func `SEED-03 seed applies a source's equality rule before dirtying`() {
  struct Reading {
    let sample: Int
    let note: String
  }

  var runs = 0
  let cogs = Cogs.forTesting()
  let source = ManualCog<Reading>(
    Reading(sample: 1, note: "first"),
    equals: { old, new in old.sample == new.sample }
  )
  let note = Cog<String> { c in
    runs += 1
    return c[source].note
  }

  #expect(cogs.peek(note) == "first")
  #expect(runs == 1)

  cogs.seed(source, to: Reading(sample: 1, note: "equal"))

  #expect(cogs.peek(note) == "first")
  #expect(runs == 1)

  cogs.seed(source, to: Reading(sample: 2, note: "changed"))

  #expect(cogs.peek(note) == "changed")
  #expect(runs == 2)
}

#endif
