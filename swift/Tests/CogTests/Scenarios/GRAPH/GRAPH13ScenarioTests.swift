import Cog
import CogTesting
import Testing

@MainActor
@Test func `GRAPH-13 a shortcut diamond settles once and never shows a torn pair`() {
  // The classic glitch topology: A feeds D both directly and through B, so
  // the two paths to D have different lengths. Naive settlement runs D after
  // the short arm alone and shows new-A beside old-B. One run per turn with a
  // consistent pair — pulled or pushed through a watcher — is the proof.
  var pairsSeen: [String] = []
  var reactionPairs: [String] = []

  let cogs = Cogs.forTesting()
  let a = ManualCog<Int>(1)
  let b = Cog<Int> { c in c[a] * 10 }
  let d = Cog<String> { c in
    let direct = c[a]
    let viaB = c[b]
    let pair = "\(direct):\(viaB)"
    pairsSeen.append(pair)
    return pair
  }

  let token = cogs.run { c in reactionPairs.append(c[d]) }
  #expect(reactionPairs == ["1:10"])
  #expect(pairsSeen == ["1:10"])

  cogs.commit { c in c[a] = 2 }

  #expect(cogs.peek(d) == "2:20")
  #expect(pairsSeen == ["1:10", "2:20"])
  #expect(reactionPairs == ["1:10", "2:20"])
  _ = token
}
