import Cog
import CogTesting
import Testing

// Value-producing calls through a retired controller cannot answer honestly, so
// they trap. These run in debug and release: the messages use `fatalError`, so
// an optimized build keeps them.

/// A workflow lifetime whose replacement retires the previous controller.
private struct Workflow: Equatable {
  let id: Int
}

/// Builds a runtime, captures the first workflow's controller, then retires it.
///
/// Every child process below needs the same setup, and the retired controller
/// has to be held strongly — a weak capture would make these calls unreachable
/// rather than inert, which is the situation the traps exist for. The runtime
/// comes back too: it must stay alive, or the trap under test would be the
/// dead-runtime one instead.
@MainActor
private func retiredController() -> (cogs: Cogs, controller: MechanismController) {
  let workflow = Cog<Workflow?>.Manual { Workflow(id: 1) }
  var captured: MechanismController?
  let cogs = Cogs.forTesting(mechanisms: [
    MechanismProbe { m in
      m.scope(workflow, name: "workflow") { selected, s in
        if selected.id == 1 { captured = s }
      }
    }
  ])
  cogs.turn(workflow, to: Workflow(id: 2))
  return (cogs, captured!)
}

/// A source and an async declaration for the reads under test.
@MainActor private let _countCog = Cog<Int>.Manual({ 0 }, name: "count")
@MainActor private let forecastCog = Cog<Int>.Async(default: 0, name: "forecast") { _ in .run { 1 }
}

/// Asserts the diagnostic names the operation, the scope, and the repair.
private func expectRetirementMessage(
  _ result: ExitTest.Result?,
  operation: String
) {
  let message = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
  #expect(message.contains("`\(operation)`"), "stderr was: \(message)")
  #expect(message.contains("Probe.workflow"), "stderr was: \(message)")
  #expect(message.contains("after it was retired"), "stderr was: \(message)")
  #expect(message.contains("ifLive"), "stderr was: \(message)")
}

@MainActor
@Test func `MECH-26 peeking through a retired controller traps`() async {
  let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
    await MainActor.run {
      let retired = retiredController()
      _ = retired.controller.peek(_countCog)
      _ = retired.cogs
    }
  }
  expectRetirementMessage(result, operation: "peek")
}

@MainActor
@Test func `MECH-26 peeking a status through a retired controller traps`() async {
  let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
    await MainActor.run {
      let retired = retiredController()
      _ = retired.controller.status.peek(forecastCog)
      _ = retired.cogs
    }
  }
  expectRetirementMessage(result, operation: "status.peek")
}

@MainActor
@Test func `MECH-26 refreshing through a retired controller traps`() async {
  // A rejected refresh must not answer `.released`: that would claim the shared
  // async state left the graph, which one ended lifetime cannot know.
  let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
    await MainActor.run {
      let retired = retiredController()
      _ = retired.controller.refresh(forecastCog)
      _ = retired.cogs
    }
  }
  expectRetirementMessage(result, operation: "refresh")
}
