import Cog
import CogTesting
import Testing

@MainActor
@Test func `GRAPH-13 a shortcut diamond settles once and never shows a torn pair`() {
  // The classic glitch topology, carrying the balanced diamond inside it: A
  // feeds D directly and through two independent automatic arms B and C, so
  // the paths to D differ in length and the join also has two dirty automatic
  // parents. Naive settlement fails this shape two ways — running D after the
  // short arm alone shows new-A beside old-B, and waking the join once per
  // changed parent runs D or an arm twice. One run per node per turn with a
  // consistent triple — pulled or pushed through a watcher — is the proof;
  // the balanced diamond's per-node exactly-once claim (the retired GRAPH-02)
  // lives in the two arm counters.
  var bRuns = 0
  var cRuns = 0
  var triplesSeen: [String] = []
  var reactionTriples: [String] = []

  let (cogs, m) = probedContext()
  let a = Cog<Int>.Manual { 1 }
  let b = Cog<Int> { c in
    bRuns += 1
    return c[a] * 10
  }
  let longArm = Cog<Int> { c in
    cRuns += 1
    return c[a] * 100
  }
  let d = Cog<String> { c in
    let direct = c[a]
    let viaB = c[b]
    let viaLongArm = c[longArm]
    let triple = "\(direct):\(viaB):\(viaLongArm)"
    triplesSeen.append(triple)
    return triple
  }

  m.run { c in reactionTriples.append(c[d]) }
  #expect(reactionTriples == ["1:10:100"])
  #expect(triplesSeen == ["1:10:100"])
  #expect(bRuns == 1)
  #expect(cRuns == 1)

  cogs.turn { c in c[a] = 2 }

  #expect(cogs.peek(d) == "2:20:200")
  #expect(triplesSeen == ["1:10:100", "2:20:200"])
  #expect(reactionTriples == ["1:10:100", "2:20:200"])
  #expect(bRuns == 2)
  #expect(cRuns == 2)
}
