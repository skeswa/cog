import Cog
import CogTesting
import Testing

// MARK: - GRAPH-07 and GRAPH-08

@MainActor
@Test func `GRAPH-07 GRAPH-08 a cold cog waits for a read and then catches up once`() {
  // One shape proves both laziness claims. Establish the internal source edge,
  // then leave the derived cog without a live UI, reaction, or stream
  // consumer. The first missed turn proves GRAPH-07: a change alone runs
  // nothing. Ten missed turns and one catch-up run from the newest value —
  // never one run per missed turn — prove GRAPH-08.
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
