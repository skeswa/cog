import CogTesting
import Testing

@testable import Cog

// M1-13a proves the structural queue without reactions. Custom equality runs
// during flush, so it supplies the same phase boundary a reaction will later
// use while keeping these tests scoped to turn machinery and internal state.

@MainActor
@Test func `TurnQueueInfrastructure defers a commit requested during flush`() {
  let cogs = Cogtext.forTesting()
  let queuedSource = ManualCog<Int>(0)
  var events: [String] = []
  var outerTurn: CogTurnID?
  var queuedTurn: CogTurnID?

  let trigger = ManualCog<Int>(
    0,
    equals: { oldValue, newValue in
      guard case .flushing(let turn) = cogs.turnPhase else {
        Issue.record("The trigger equality did not run while flushing")
        return oldValue == newValue
      }
      outerTurn = turn.id
      events.append("outer flush before enqueue")

      cogs.commit("queued") { writer in
        guard case .accumulating(let turn) = cogs.turnPhase else {
          Issue.record("The queued body did not run while accumulating")
          return
        }
        queuedTurn = turn.id
        events.append("queued body")
        #expect(writer[queuedSource] == 0)
        writer[queuedSource] = 1
      }

      events.append("outer flush after enqueue")
      #expect(cogs.read(queuedSource) == 0)
      return oldValue == newValue
    }
  )

  cogs.commit("outer") { writer in
    events.append("outer body")
    writer[trigger] = 1
  }

  #expect(
    events == [
      "outer body",
      "outer flush before enqueue",
      "outer flush after enqueue",
      "queued body",
    ])
  #expect(outerTurn != nil)
  #expect(queuedTurn != nil)
  #expect(queuedTurn !== outerTurn)
  #expect(cogs.read(queuedSource) == 1)
  #expect(cogs.queuedTurns.isEmpty)
  guard case .idle = cogs.turnPhase else {
    Issue.record("The queue did not drain back to idle")
    return
  }
}

@MainActor
@Test func `TurnQueueInfrastructure drains arrivals in FIFO order without reentry`() {
  let cogs = Cogtext.forTesting()
  let value = ManualCog<Int>(0)
  var events: [String] = []
  var valuesSeen: [Int] = []
  var turnIDs: [CogTurnID] = []
  var turnNames: [String] = []

  func recordQueuedTurn(_ expectedName: String) {
    guard case .accumulating(let turn) = cogs.turnPhase else {
      Issue.record("\(expectedName) did not run while accumulating")
      return
    }
    turnIDs.append(turn.id)
    turnNames.append(turn.name)
  }

  let firstFlushTrigger = ManualCog<Int>(
    0,
    equals: { oldValue, newValue in
      events.append("first flush")
      cogs.commit("late") { writer in
        recordQueuedTurn("late")
        events.append("late body")
        valuesSeen.append(writer[value])
        writer[value] = 3
      }
      return oldValue == newValue
    }
  )

  let outerFlushTrigger = ManualCog<Int>(
    0,
    equals: { oldValue, newValue in
      events.append("outer flush")

      cogs.commit("first") { writer in
        recordQueuedTurn("first")
        events.append("first body")
        valuesSeen.append(writer[value])
        writer[firstFlushTrigger] = 1
        writer[value] = 1
      }

      cogs.commit("second") { writer in
        recordQueuedTurn("second")
        events.append("second body")
        valuesSeen.append(writer[value])
        writer[value] = 2
      }

      return oldValue == newValue
    }
  )

  cogs.commit("outer") { writer in writer[outerFlushTrigger] = 1 }

  #expect(
    events == [
      "outer flush",
      "first body",
      "first flush",
      "second body",
      "late body",
    ])
  #expect(valuesSeen == [0, 1, 2])
  #expect(turnNames == ["first", "second", "late"])
  #expect(Set(turnIDs.map(ObjectIdentifier.init)).count == 3)
  #expect(cogs.read(value) == 3)
  #expect(cogs.queuedTurns.isEmpty)
  guard case .idle = cogs.turnPhase else {
    Issue.record("The growing queue did not drain back to idle")
    return
  }
}
