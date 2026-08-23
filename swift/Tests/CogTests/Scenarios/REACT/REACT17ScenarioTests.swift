#if DEBUG

import Cog
import CogTesting
import Testing

@MainActor
@Test func `REACT-17 a finite reaction loop warns and returns idle`() throws {
  let ping = Cog<Int>.Manual(0)
  let pong = Cog<Int>.Manual(0)
  var reactionRuns = 0
  var pingReactionLine: UInt = 0
  var pongReactionLine: UInt = 0

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      pingReactionLine = UInt(#line) + 1
      m.run { c in
        let value = c[ping]
        guard value > 0 else { return }

        reactionRuns += 1
        guard value < 65 else { return }
        m.turn("react17.turn.\(value + 1)") { c in
          c[pong] = value + 1
        }
      }

      pongReactionLine = UInt(#line) + 1
      m.run { c in
        let value = c[pong]
        guard value > 0 else { return }

        reactionRuns += 1
        guard value < 65 else { return }
        m.turn("react17.turn.\(value + 1)") { c in
          c[ping] = value + 1
        }
      }
    }
  ])

  #expect(cogs.turnChainDiagnostic.warningCount == 0)
  #expect(cogs.turnChainDiagnostic.isIdle)

  var initiatingBodySawBusyContext = false
  cogs.turn("react17.turn.1") { c in
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
      .turn(turn == 1 ? "react17.turn.1" : "Probe.react17.turn.\(turn)"),
      .reaction(turn.isMultiple(of: 2) ? pongReactionName : pingReactionName),
    ]
  }
  #expect(warning.causalChain == expectedChain)
}

@MainActor
@Test func `REACT-17 a chain at the threshold stays warning-free`() {
  // Pins the lower edge of "about 64": a chain of exactly 64 uninterrupted
  // turns is quiet, so the warning cannot silently regress toward warning on
  // ordinary short chains.
  let ping = Cog<Int>.Manual(0)
  let pong = Cog<Int>.Manual(0)

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.run { c in
        let value = c[ping]
        guard value > 0, value < 64 else { return }
        m.turn("react17.edge.\(value + 1)") { c in
          c[pong] = value + 1
        }
      }
      m.run { c in
        let value = c[pong]
        guard value > 0, value < 64 else { return }
        m.turn("react17.edge.\(value + 1)") { c in
          c[ping] = value + 1
        }
      }
    }
  ])

  cogs.turn("react17.edge.1") { c in c[ping] = 1 }

  // Sixty-four turns ran as one chain, and none of them warned.
  #expect(cogs.peek(ping) == 63)
  #expect(cogs.peek(pong) == 64)
  #expect(cogs.turnChainDiagnostic.warningCount == 0)
  #expect(cogs.turnChainDiagnostic.lastWarning == nil)
  #expect(cogs.turnChainDiagnostic.isIdle)
}

@MainActor
@Test func `REACT-17 a cause-heavy chain truncates its causal trace honestly`() throws {
  // Enough reactions per turn overflow the bounded causal trace before the
  // turn threshold. The warning still fires once, keeps its bounded prefix,
  // and says that it truncated instead of silently dropping causes.
  let ping = Cog<Int>.Manual(0)
  let pong = Cog<Int>.Manual(0)

  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      for _ in 0..<4 {
        m.run { c in
          _ = c[ping]
          _ = c[pong]
        }
      }
      m.run { c in
        let value = c[ping]
        guard value > 0, value < 65 else { return }
        m.turn("react17.heavy.\(value + 1)") { c in
          c[pong] = value + 1
        }
      }
      m.run { c in
        let value = c[pong]
        guard value > 0, value < 65 else { return }
        m.turn("react17.heavy.\(value + 1)") { c in
          c[ping] = value + 1
        }
      }
    }
  ])

  cogs.turn("react17.heavy.1") { c in c[ping] = 1 }

  let diagnostic = cogs.turnChainDiagnostic
  let warning = try #require(diagnostic.lastWarning)
  #expect(diagnostic.warningCount == 1)
  #expect(diagnostic.isIdle)
  #expect(warning.uninterruptedTurnCount == 65)
  #expect(warning.causalChainIsTruncated)
  #expect(warning.causalChain.count == 256)
}

@MainActor
@Test func `REACT-17 turns separated by idle do not form one turn chain`() {
  let cogs = Cogs.forTesting()
  let source = Cog<Int>.Manual(0)

  for turn in 1...65 {
    cogs.turn("react17.separate.\(turn)") { c in
      c[source] = turn
    }
    #expect(cogs.turnChainDiagnostic.isIdle)
  }

  #expect(cogs.peek(source) == 65)
  #expect(cogs.turnChainDiagnostic.warningCount == 0)
  #expect(cogs.turnChainDiagnostic.lastWarning == nil)
}

#endif
