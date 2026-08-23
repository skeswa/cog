import Cog
import CogTesting
import Testing

@MainActor
@Test func `GRAPH-13 a shortcut diamond settles once and never shows a torn pair`() {
  // The classic glitch topology: A feeds D both directly and through B, so
  // the two paths to D have different lengths. Naive settlement runs D after
  // the short arm alone and shows new-A beside old-B. One run per turn with a
  // consistent pair — pulled or pushed through a watcher — is the proof. The
  // arm's run count is asserted too: the balanced diamond's per-node
  // exactly-once claim (the retired GRAPH-02) lives here now, and this
  // harder shape must not buy its consistency with a second arm run.
  var bRuns = 0
  var pairsSeen: [String] = []
  var reactionPairs: [String] = []

  let (cogs, m) = probedContext()
  let a = Cog<Int>.Manual(1)
  let b = Cog<Int> { c in
    bRuns += 1
    return c[a] * 10
  }
  let d = Cog<String> { c in
    let direct = c[a]
    let viaB = c[b]
    let pair = "\(direct):\(viaB)"
    pairsSeen.append(pair)
    return pair
  }

  m.run { c in reactionPairs.append(c[d]) }
  #expect(reactionPairs == ["1:10"])
  #expect(pairsSeen == ["1:10"])
  #expect(bRuns == 1)

  cogs.turn { c in c[a] = 2 }

  #expect(cogs.peek(d) == "2:20")
  #expect(pairsSeen == ["1:10", "2:20"])
  #expect(reactionPairs == ["1:10", "2:20"])
  #expect(bRuns == 2)
}
