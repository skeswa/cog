import CogTesting
import Testing

@testable import Cog

// Internal phase checks for one commit. Scenario tests cover public commit
// behavior.

@MainActor
@Test func `TurnStateInfrastructure advances through one turn and returns to idle`() {
  let cogs = Cogs.forTesting()

  guard case .idle = cogs.turnPhase else {
    Issue.record("A new context did not start idle")
    return
  }

  let turn = cogs.startTurn(named: "refreshWeather")
  guard case .accumulating(let accumulating) = cogs.turnPhase else {
    Issue.record("The context did not start accumulating")
    return
  }
  #expect(accumulating.id == turn.id)

  cogs.startFlushing(turn.id)
  guard case .flushing(let flushing) = cogs.turnPhase else {
    Issue.record("The context did not start flushing")
    return
  }
  #expect(flushing.id == turn.id)

  cogs.finishTurn(turn.id)
  guard case .idle = cogs.turnPhase else {
    Issue.record("The context did not return to idle")
    return
  }
}

@MainActor
@Test func `TurnStateInfrastructure captures a custom turn name`() {
  let cogs = Cogs.forTesting()

  cogs.withTurn("refreshWeather") { turn in
    #expect(turn.name == "refreshWeather")

    guard case .accumulating(let active) = cogs.turnPhase else {
      Issue.record("The turn body did not run while accumulating")
      return
    }
    #expect(active.id == turn.id)
  }
}

@MainActor
@Test func `TurnStateInfrastructure captures the calling function by default`() {
  let cogs = Cogs.forTesting()

  #expect(defaultTurnName(in: cogs) == "defaultTurnName(in:)")
}

@MainActor
private func defaultTurnName(in cogs: Cogs) -> String {
  var captured = ""
  cogs.withTurn { turn in
    captured = turn.name
  }
  return captured
}

@MainActor
@Test func `TurnStateInfrastructure gives every turn an identity Cog alone minted`() {
  let cogs = Cogs.forTesting()
  var first: CogTurnID?
  var second: CogTurnID?

  cogs.withTurn("first") { first = $0.id }
  cogs.withTurn("second") { second = $0.id }

  #expect(first != nil)
  #expect(second != nil)
  #expect(first != second)
}

@MainActor
@Test func `TurnStateInfrastructure keeps keyless pending state apart from committed state`() {
  let cogs = Cogs.forTesting()
  let selectedZip = ManualCog<String?>("10001")
  let state = cogs.manualState(for: selectedZip)

  #expect(state.key == nil)
  #expect(state.currentValue == "10001")
  #expect(state.pendingValue == nil)

  // The outer optional means "a write is staged"; the inner one is the
  // source's value. A staged nil must not look like no staged write.
  state.pendingValue = .some(nil)

  #expect(state.currentValue == "10001")
  guard case .some(.none) = state.pendingValue else {
    Issue.record("A staged nil was lost")
    return
  }
}
