import CogTesting
import Testing

@testable import Cog

// `M1-04aa`'s turn-state machinery, asserted directly. These tests green no
// scenario: `M1-04ab` proves the public commit behavior that rests on it.
// Keeping the phase representation here, away from scenario tests, lets the
// later data-oriented core replace it without changing a behavior test.

@MainActor
@Test func `TurnStateInfrastructure advances through one turn and returns to idle`() {
  let cogs = Cogtext.forTesting()

  guard case .idle = cogs.turnPhase else {
    Issue.record("A new context did not start idle")
    return
  }

  let turn = cogs.startTurn(named: "refreshWeather")
  guard case .accumulating(let accumulating) = cogs.turnPhase else {
    Issue.record("The context did not start accumulating")
    return
  }
  #expect(accumulating.id === turn.id)

  cogs.startFlushing(turn.id)
  guard case .flushing(let flushing) = cogs.turnPhase else {
    Issue.record("The context did not start flushing")
    return
  }
  #expect(flushing.id === turn.id)

  cogs.finishTurn(turn.id)
  guard case .idle = cogs.turnPhase else {
    Issue.record("The context did not return to idle")
    return
  }
}

@MainActor
@Test func `TurnStateInfrastructure captures a custom turn name`() {
  let cogs = Cogtext.forTesting()

  cogs.withTurn("refreshWeather") { turn in
    #expect(turn.name == "refreshWeather")

    guard case .accumulating(let active) = cogs.turnPhase else {
      Issue.record("The turn body did not run while accumulating")
      return
    }
    #expect(active.id === turn.id)
  }
}

@MainActor
@Test func `TurnStateInfrastructure captures the calling function by default`() {
  let cogs = Cogtext.forTesting()

  #expect(defaultTurnName(in: cogs) == "defaultTurnName(in:)")
}

@MainActor
private func defaultTurnName(in cogs: Cogtext) -> String {
  var captured = ""
  cogs.withTurn { turn in
    captured = turn.name
  }
  return captured
}

@MainActor
@Test func `TurnStateInfrastructure gives every turn an identity Cog alone minted`() {
  let cogs = Cogtext.forTesting()
  var first: CogTurnID?
  var second: CogTurnID?

  cogs.withTurn("first") { first = $0.id }
  cogs.withTurn("second") { second = $0.id }

  #expect(first != nil)
  #expect(second != nil)
  #expect(first !== second)
}

@MainActor
@Test func `TurnStateInfrastructure keeps keyless pending state apart from committed state`() {
  let cogs = Cogtext.forTesting()
  let selectedZip = ManualCog<String?>("10001")
  let node = cogs.manualNode(for: selectedZip)

  #expect(node.key == nil)
  #expect(node.currentValue == "10001")
  #expect(node.pendingValue == nil)

  // The outer optional means "a write is staged"; the inner one is the
  // source's value. A staged nil must not look like no staged write.
  node.pendingValue = .some(nil)

  #expect(node.currentValue == "10001")
  guard case .some(.none) = node.pendingValue else {
    Issue.record("A staged nil was lost")
    return
  }
}
