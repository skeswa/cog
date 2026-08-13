import Cog
import CogTesting
import Testing

// MARK: - GRAPH-07 and GRAPH-08

@MainActor
@Test func `GRAPH-07 a cold derived cog waits for a later read to recompute`() {
  let cogs = Cogs.forTesting()
  let source = ManualCog<Int>(1)
  var inputsSeen: [Int] = []
  let doubled = Cog<Int> { c in
    let input = c[source]
    inputsSeen.append(input)
    return input * 2
  }

  // Establish the internal source edge, then leave the derived cog without a
  // live UI, reaction, or stream consumer.
  #expect(cogs.peek(doubled) == 2)
  #expect(inputsSeen == [1])

  cogs.commit { c in c[source] = 2 }

  #expect(cogs.peek(source) == 2)
  #expect(inputsSeen == [1])
  #expect(cogs.peek(doubled) == 4)
  #expect(inputsSeen == [1, 2])
}

@MainActor
@Test func `GRAPH-08 a cold cog catches up once after ten missed turns`() {
  let cogs = Cogs.forTesting()
  let source = ManualCog<Int>(0)
  var inputsSeen: [Int] = []
  let scaled = Cog<Int> { c in
    let input = c[source]
    inputsSeen.append(input)
    return input * 10
  }

  #expect(cogs.peek(scaled) == 0)
  #expect(inputsSeen == [0])

  for value in 1...10 {
    cogs.commit { c in c[source] = value }
    #expect(cogs.peek(source) == value)
    #expect(inputsSeen == [0])
  }

  #expect(cogs.peek(scaled) == 100)
  #expect(inputsSeen == [0, 10])
}
