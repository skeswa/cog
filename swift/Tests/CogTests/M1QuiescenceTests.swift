#if DEBUG

import Cog
import CogTesting
import Testing

@MainActor
@Test func `REACT-17 a finite reaction loop warns and returns quiescent`() throws {
  let cogs = Cogtext.forTesting()
  let ping = ManualCog<Int>(0)
  let pong = ManualCog<Int>(0)
  var reactionRuns = 0

  let pingReactionLine = UInt(#line) + 1
  let pingReaction = cogs.run { c in
    let value = c.get(ping)
    guard value > 0 else { return }

    reactionRuns += 1
    guard value < 65 else { return }
    cogs.commit("react17.turn.\(value + 1)") { w in
      w[pong] = value + 1
    }
  }

  let pongReactionLine = UInt(#line) + 1
  let pongReaction = cogs.run { c in
    let value = c.get(pong)
    guard value > 0 else { return }

    reactionRuns += 1
    guard value < 65 else { return }
    cogs.commit("react17.turn.\(value + 1)") { w in
      w[ping] = value + 1
    }
  }

  #expect(cogs.quiescenceDiagnostic.warningCount == 0)
  #expect(cogs.quiescenceDiagnostic.isIdle)

  var initiatingBodySawBusyContext = false
  cogs.commit("react17.turn.1") { w in
    initiatingBodySawBusyContext = !cogs.quiescenceDiagnostic.isIdle
    w[ping] = 1
  }

  // The initiating call does not return until every reaction write-back has
  // drained. No task, await, yield, poll, sleep, or timeout stands between the
  // op and these assertions.
  #expect(cogs.read(ping) == 65)
  #expect(cogs.read(pong) == 64)
  #expect(reactionRuns == 65)
  #expect(initiatingBodySawBusyContext)

  let diagnostic = cogs.quiescenceDiagnostic
  let warning = try #require(diagnostic.lastWarning)
  #expect(diagnostic.warningCount == 1)
  #expect(diagnostic.isIdle)
  #expect(warning.uninterruptedTurnCount == 65)
  #expect(!warning.causalChainIsTruncated)

  let pingReactionName = "\(#fileID):\(pingReactionLine)"
  let pongReactionName = "\(#fileID):\(pongReactionLine)"
  let expectedChain = (1...65).flatMap { turn -> [CogQuiescenceCause] in
    [
      .turn("react17.turn.\(turn)"),
      .reaction(turn.isMultiple(of: 2) ? pongReactionName : pingReactionName),
    ]
  }
  #expect(warning.causalChain == expectedChain)

  _ = (pingReaction, pongReaction)
}

@MainActor
@Test func `REACT-17 turns separated by idle do not form one causal episode`() {
  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(0)

  for turn in 1...65 {
    cogs.commit("react17.separate.\(turn)") { w in
      w[source] = turn
    }
    #expect(cogs.quiescenceDiagnostic.isIdle)
  }

  #expect(cogs.read(source) == 65)
  #expect(cogs.quiescenceDiagnostic.warningCount == 0)
  #expect(cogs.quiescenceDiagnostic.lastWarning == nil)
}

#endif
