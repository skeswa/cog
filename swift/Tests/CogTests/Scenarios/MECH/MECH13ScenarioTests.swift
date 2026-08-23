import Cog
import CogTesting
import Testing

@MainActor private let stepCountCog = Cog<Int>.Manual(0)

// One op definition on the shared protocol serves both capabilities.
@MainActor extension CogOps {
  fileprivate func advanceStep() {
    turn { c in c[stepCountCog] += 1 }
  }
}

@MainActor
@Test func `MECH-13 one op definition serves cogs and the controller`() {
  var m: MechanismController!
  let cogs = Cogs.forTesting(mechanisms: [MechanismProbe { m = $0 }])

  // App code calls the op on the runtime; a mechanism calls the same
  // definition on its controller. Both write the same source.
  cogs.advanceStep()
  m.advanceStep()
  #expect(cogs.peek(stepCountCog) == 2)

  #if DEBUG
  // Both turns carry the op's `#function` name, and the mechanism's call is
  // attributed to its mechanism.
  let turns = cogs.debugHistory.entries.filter { $0.event == .turn }
  #expect(turns.map(\.name) == ["advanceStep()", "Probe.advanceStep()"])
  #endif
}
