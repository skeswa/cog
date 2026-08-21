import Cog
import CogTesting
import Testing

// Selector-owned counters make automatic equality visible through public reads.

@MainActor
@Test func `GRAPH-05 an equal middle value stops the downstream wave`() {
  var middleRuns = 0
  var leafRuns = 0

  let cogs = Cogs.forTesting()
  let source = ManualCog<Int>(1)
  let isPositive = Cog<Bool> { c in
    middleRuns += 1
    return c[source] > 0
  }
  let message = Cog<String> { c in
    leafRuns += 1
    return c[isPositive] ? "positive" : "not positive"
  }

  #expect(cogs.peek(message) == "positive")
  #expect(middleRuns == 1)
  #expect(leafRuns == 1)

  cogs.turn { c in c[source] = 2 }

  #expect(cogs.peek(message) == "positive")
  #expect(middleRuns == 2)
  #expect(leafRuns == 1)
}

@MainActor
@Test func `GRAPH-05 custom automatic equality can stop the downstream wave`() {
  struct Summary {
    let bucket: Int
    let raw: Int
  }

  var middleRuns = 0
  var leafRuns = 0

  let cogs = Cogs.forTesting()
  let source = ManualCog<Int>(11)
  let summary = Cog<Summary>(
    { c in
      middleRuns += 1
      let value = c[source]
      return Summary(bucket: value / 10, raw: value)
    },
    equals: { old, new in old.bucket == new.bucket }
  )
  let bucket = Cog<Int> { c in
    leafRuns += 1
    return c[summary].bucket
  }

  #expect(cogs.peek(bucket) == 1)

  cogs.turn { c in c[source] = 12 }

  #expect(cogs.peek(bucket) == 1)
  #expect(middleRuns == 2)
  #expect(leafRuns == 1)
}

@MainActor
@Test func `GRAPH-06 a changed middle value keeps the downstream wave moving`() {
  var middleRuns = 0
  var lowerRuns = 0
  var leafRuns = 0

  let cogs = Cogs.forTesting()
  let source = ManualCog<Int>(1)
  let doubled = Cog<Int> { c in
    middleRuns += 1
    return c[source] * 2
  }
  let lower = Cog<Int> { c in
    lowerRuns += 1
    return c[doubled] + 1
  }
  let leaf = Cog<String> { c in
    leafRuns += 1
    return "value=\(c[lower])"
  }

  #expect(cogs.peek(leaf) == "value=3")

  for next in 2...4 {
    cogs.turn { c in c[source] = next }
    #expect(cogs.peek(leaf) == "value=\(next * 2 + 1)")
  }

  #expect(middleRuns == 4)
  #expect(lowerRuns == 4)
  #expect(leafRuns == 4)
}

@MainActor
@Test func `GRAPH-06 a non-Equatable middle conservatively continues the wave`() {
  struct Parity {
    let isEven: Bool
  }

  var middleRuns = 0
  var leafRuns = 0

  let cogs = Cogs.forTesting()
  let source = ManualCog<Int>(1)
  let parity = Cog<Parity> { c in
    middleRuns += 1
    return Parity(isEven: c[source].isMultiple(of: 2))
  }
  let message = Cog<String> { c in
    leafRuns += 1
    return c[parity].isEven ? "even" : "odd"
  }

  #expect(cogs.peek(message) == "odd")

  cogs.turn { c in c[source] = 3 }

  #expect(cogs.peek(message) == "odd")
  #expect(middleRuns == 2)
  #expect(leafRuns == 2)
}
