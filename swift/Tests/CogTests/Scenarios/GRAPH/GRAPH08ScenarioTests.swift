import Cog
import CogTesting
import Testing

@MainActor
@Test func `GRAPH-08 a cold cog waits for a read and then catches up once`() {
  // One shape proves both laziness claims. Establish the internal source edge,
  // then leave the automatic cog without a live UI, reaction, or stream
  // consumer. The first missed turn already runs nothing — the retired
  // GRAPH-07's whole claim, still asserted by the loop's first pass. Ten
  // missed turns and one catch-up run from the newest value — never one run
  // per missed turn — are GRAPH-08's own.
  let cogs = Cogs.forTesting()
  let source = Cog<Int>.Manual(0)
  var inputsSeen: [Int] = []
  let scaled = Cog<Int> { c in
    let input = c[source]
    inputsSeen.append(input)
    return input * 10
  }

  #expect(cogs.peek(scaled) == 0)
  #expect(inputsSeen == [0])

  for value in 1...10 {
    cogs.turn { c in c[source] = value }
    #expect(cogs.peek(source) == value)
    #expect(inputsSeen == [0])
  }

  #expect(cogs.peek(scaled) == 100)
  #expect(inputsSeen == [0, 10])
}
