#if DEBUG

import Cog
import CogTesting
import Testing

@MainActor
@Test func `REACT-17 a finite reaction loop warns and returns idle`() throws {
  let cogs = Cogs.forTesting()
  let ping = ManualCog<Int>(0)
  let pong = ManualCog<Int>(0)
  var reactionRuns = 0

  let pingReactionLine = UInt(#line) + 1
  let pingReaction = cogs.run { c in
    let value = c[ping]
    guard value > 0 else { return }

    reactionRuns += 1
    guard value < 65 else { return }
    cogs.commit("react17.turn.\(value + 1)") { c in
      c[pong] = value + 1
    }
  }

  let pongReactionLine = UInt(#line) + 1
  let pongReaction = cogs.run { c in
    let value = c[pong]
    guard value > 0 else { return }

    reactionRuns += 1
    guard value < 65 else { return }
    cogs.commit("react17.turn.\(value + 1)") { c in
      c[ping] = value + 1
    }
  }

  #expect(cogs.turnChainDiagnostic.warningCount == 0)
  #expect(cogs.turnChainDiagnostic.isIdle)

  var initiatingBodySawBusyContext = false
  cogs.commit("react17.turn.1") { c in
    initiatingBodySawBusyContext = !cogs.turnChainDiagnostic.isIdle
    c[ping] = 1
  }

  // The initiating call does not return until every reaction write-back has
  // drained. No task, await, yield, poll, sleep, or timeout stands between the
  // op and these assertions.
  #expect(cogs.peek(ping) == 65)
  #expect(cogs.peek(pong) == 64)
  #expect(reactionRuns == 65)
  #expect(initiatingBodySawBusyContext)

  let diagnostic = cogs.turnChainDiagnostic
  let warning = try #require(diagnostic.lastWarning)
  #expect(diagnostic.warningCount == 1)
  #expect(diagnostic.isIdle)
  #expect(warning.uninterruptedTurnCount == 65)
  #expect(!warning.causalChainIsTruncated)

  let pingReactionName = "\(#fileID):\(pingReactionLine)"
  let pongReactionName = "\(#fileID):\(pongReactionLine)"
  let expectedChain = (1...65).flatMap { turn -> [CogTurnChainCause] in
    [
      .turn("react17.turn.\(turn)"),
      .reaction(turn.isMultiple(of: 2) ? pongReactionName : pingReactionName),
    ]
  }
  #expect(warning.causalChain == expectedChain)

  _ = (pingReaction, pongReaction)
}

@MainActor
@Test func `REACT-17 turns separated by idle do not form one turn chain`() {
  let cogs = Cogs.forTesting()
  let source = ManualCog<Int>(0)

  for turn in 1...65 {
    cogs.commit("react17.separate.\(turn)") { c in
      c[source] = turn
    }
    #expect(cogs.turnChainDiagnostic.isIdle)
  }

  #expect(cogs.peek(source) == 65)
  #expect(cogs.turnChainDiagnostic.warningCount == 0)
  #expect(cogs.turnChainDiagnostic.lastWarning == nil)
}

#endif
