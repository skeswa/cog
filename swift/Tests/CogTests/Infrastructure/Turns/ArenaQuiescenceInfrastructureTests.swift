import CogTesting
import Testing

@testable import Cog

#if DEBUG

// Internal proof that the public turn-chain snapshot includes arena-only
// selector state. Public REACT-17 scenarios verify the resulting behavior.

@MainActor
@Test func `ArenaQuiescenceInfrastructure reports an active selector as busy`() {
  let cogs = Cogs.forTesting()
  var selectorSawIdle = true
  let selected = Cog<Int> { _ in
    selectorSawIdle = cogs.turnChainDiagnosticSnapshot.isIdle
    return 1
  }

  #expect(cogs.turnChainDiagnosticSnapshot.isIdle)
  #expect(cogs.peek(selected) == 1)
  #expect(!selectorSawIdle)
  #expect(cogs.turnChainDiagnosticSnapshot.isIdle)
}

#endif
