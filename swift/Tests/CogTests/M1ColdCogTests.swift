import Cog
import CogTesting
import Testing

@MainActor
@Test func `GRAPH-07 a cold derived cog waits for a later read to recompute`() {
  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(1)
  var inputsSeen: [Int] = []
  let doubled = Cog<Int> { c in
    let input = c.get(source)
    inputsSeen.append(input)
    return input * 2
  }

  // Establish the internal source edge, then leave the derived cog without a
  // live UI, reaction, or stream consumer.
  #expect(cogs.read(doubled) == 2)
  #expect(inputsSeen == [1])

  cogs.commit { w in w[source] = 2 }

  #expect(cogs.read(source) == 2)
  #expect(inputsSeen == [1])
  #expect(cogs.read(doubled) == 4)
  #expect(inputsSeen == [1, 2])
}

@MainActor
@Test func `GRAPH-08 a cold cog catches up once after ten missed turns`() {
  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(0)
  var inputsSeen: [Int] = []
  let scaled = Cog<Int> { c in
    let input = c.get(source)
    inputsSeen.append(input)
    return input * 10
  }

  #expect(cogs.read(scaled) == 0)
  #expect(inputsSeen == [0])

  for value in 1...10 {
    cogs.commit { w in w[source] = value }
    #expect(cogs.read(source) == value)
    #expect(inputsSeen == [0])
  }

  #expect(cogs.read(scaled) == 100)
  #expect(inputsSeen == [0, 10])
}

@MainActor
@Test func `READ-07 a one-shot read settles without subscribing`() {
  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(1)
  var inputsSeen: [Int] = []
  let doubled = Cog<Int> { c in
    let input = c.get(source)
    inputsSeen.append(input)
    return input * 2
  }

  #expect(cogs.read(doubled) == 2)

  cogs.commit { w in w[source] = 2 }
  #expect(inputsSeen == [1])
  #expect(cogs.read(doubled) == 4)
  #expect(inputsSeen == [1, 2])

  // The catch-up read above must not leave the root hot. A later turn dirties
  // it but does not run it, and another one-shot read still settles it.
  cogs.commit { w in w[source] = 3 }
  #expect(cogs.read(source) == 3)
  #expect(inputsSeen == [1, 2])
  #expect(cogs.read(doubled) == 6)
  #expect(inputsSeen == [1, 2, 3])
}

@MainActor
@Test func `READ-07 a one-shot read creates no dependency on its ambient selector`() {
  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(1)
  let trigger = ManualCog<Int>(0)
  var innerInputs: [Int] = []
  var outerRuns = 0

  let doubled = Cog<Int> { c in
    let input = c.get(source)
    innerInputs.append(input)
    return input * 2
  }
  let snapshot = Cog<Int> { c in
    _ = c.get(trigger)
    outerRuns += 1
    return cogs.read(doubled)
  }

  #expect(cogs.read(snapshot) == 2)
  #expect(innerInputs == [1])
  #expect(outerRuns == 1)

  cogs.commit { w in
    w[source] = 2
    w[trigger] = 1
  }
  #expect(innerInputs == [1])
  #expect(cogs.read(snapshot) == 4)
  #expect(innerInputs == [1, 2])
  #expect(outerRuns == 2)

  // A source-only turn dirties the inner cog. If the one-shot read had linked
  // it to the ambient selector, pulling the selector would now rerun it.
  cogs.commit { w in w[source] = 3 }
  #expect(cogs.read(source) == 3)
  #expect(innerInputs == [1, 2])
  #expect(cogs.read(snapshot) == 4)
  #expect(outerRuns == 2)
  #expect(cogs.read(doubled) == 6)
  #expect(innerInputs == [1, 2, 3])
}
