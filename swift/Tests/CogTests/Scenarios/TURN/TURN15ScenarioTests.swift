import Cog
import CogTesting
import Testing

// The commit boundary holds for settlement too: a derived cog settled while a
// commit body is still running computes from committed values, never from the
// turn's staged writes.

@MainActor
@Test func `TURN-15 mid-commit settlement uses committed values only`() {
  var inputsSeen: [Int] = []

  let cogs = Cogs.forTesting()
  let source = ManualCog<Int>(1)
  let doubled = Cog<Int> { c in
    let input = c[source]
    inputsSeen.append(input)
    return input * 2
  }

  // The derived cog is cold on purpose: the mid-commit read is what settles
  // it, so an implementation that settles against staged values would compute
  // from 5 here.
  cogs.commit { c in
    c[source] = 5

    #expect(cogs.peek(doubled) == 2)
    #expect(inputsSeen == [1])
    #expect(c[source] == 5)
  }

  #expect(cogs.peek(doubled) == 10)
  #expect(inputsSeen == [1, 5])
}

@MainActor
@Test func `TURN-15 a stale derived cog settles mid-commit at the latest committed turn`() {
  var inputsSeen: [Int] = []

  let cogs = Cogs.forTesting()
  let source = ManualCog<Int>(1)
  let doubled = Cog<Int> { c in
    let input = c[source]
    inputsSeen.append(input)
    return input * 2
  }

  #expect(cogs.peek(doubled) == 2)

  // Leave the derived cog dirty from an earlier committed turn, then read it
  // while a later commit is accumulating: it catches up to the last committed
  // value, not to this turn's staged one and not to the value it last saw.
  cogs.commit { c in c[source] = 3 }
  cogs.commit { c in
    c[source] = 7

    #expect(cogs.peek(doubled) == 6)
    #expect(inputsSeen == [1, 3])
  }

  #expect(cogs.peek(doubled) == 14)
  #expect(inputsSeen == [1, 3, 7])
}
