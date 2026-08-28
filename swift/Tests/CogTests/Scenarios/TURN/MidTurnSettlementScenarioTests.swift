import Cog
import CogTesting
import Testing

// The turn boundary holds for settlement too: an automatic cog settled while a
// turn body is still running computes from published values, never from the
// turn's staged writes.

@MainActor
@Test func `TURN-15 mid-turn settlement uses published values only`() {
  var inputsSeen: [Int] = []

  let cogs = Cogs.forTesting()
  let source = Cog<Int>.Manual { 1 }
  let doubled = Cog<Int> { c in
    let input = c[source]
    inputsSeen.append(input)
    return input * 2
  }

  // The automatic cog is cold on purpose: the mid-turn read is what settles
  // it, so an implementation that settles against staged values would compute
  // from 5 here.
  cogs.turn { c in
    c[source] = 5

    #expect(cogs.peek(doubled) == 2)
    #expect(inputsSeen == [1])
    #expect(c[source] == 5)
  }

  #expect(cogs.peek(doubled) == 10)
  #expect(inputsSeen == [1, 5])
}

@MainActor
@Test func `TURN-15 a stale automatic cog settles mid-turn at the latest published turn`() {
  var inputsSeen: [Int] = []

  let cogs = Cogs.forTesting()
  let source = Cog<Int>.Manual { 1 }
  let doubled = Cog<Int> { c in
    let input = c[source]
    inputsSeen.append(input)
    return input * 2
  }

  #expect(cogs.peek(doubled) == 2)

  // Leave the automatic cog dirty from an earlier published turn, then read it
  // while a later turn is accumulating: it catches up to the last published
  // value, not to this turn's staged one and not to the value it last saw.
  cogs.turn { c in c[source] = 3 }
  cogs.turn { c in
    c[source] = 7

    #expect(cogs.peek(doubled) == 6)
    #expect(inputsSeen == [1, 3])
  }

  #expect(cogs.peek(doubled) == 14)
  #expect(inputsSeen == [1, 3, 7])
}
