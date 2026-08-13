import CogTesting
import Testing

@testable import Cog

// Custom equality runs during flush, letting these tests enqueue another turn
// without depending on reactions.

@MainActor
@Test func `TurnQueueInfrastructure defers a commit requested during flush`() {
  let cogs = Cogs.forTesting()
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

      cogs.commit("queued") { c in
        guard case .accumulating(let turn) = cogs.turnPhase else {
          Issue.record("The queued body did not run while accumulating")
          return
        }
        queuedTurn = turn.id
        events.append("queued body")
        #expect(c[queuedSource] == 0)
        c[queuedSource] = 1
      }

      events.append("outer flush after enqueue")
      #expect(cogs.peek(queuedSource) == 0)
      return oldValue == newValue
    }
  )

  cogs.commit("outer") { c in
    events.append("outer body")
    c[trigger] = 1
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
  #expect(cogs.peek(queuedSource) == 1)
  #expect(cogs.queuedTurns.isEmpty)
  guard case .idle = cogs.turnPhase else {
    Issue.record("The queue did not drain back to idle")
    return
  }
}

@MainActor
@Test func `TurnQueueInfrastructure drains arrivals in FIFO order without reentry`() {
  let cogs = Cogs.forTesting()
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
      cogs.commit("late") { c in
        recordQueuedTurn("late")
        events.append("late body")
        valuesSeen.append(c[value])
        c[value] = 3
      }
      return oldValue == newValue
    }
  )

  let outerFlushTrigger = ManualCog<Int>(
    0,
    equals: { oldValue, newValue in
      events.append("outer flush")

      cogs.commit("first") { c in
        recordQueuedTurn("first")
        events.append("first body")
        valuesSeen.append(c[value])
        c[firstFlushTrigger] = 1
        c[value] = 1
      }

      cogs.commit("second") { c in
        recordQueuedTurn("second")
        events.append("second body")
        valuesSeen.append(c[value])
        c[value] = 2
      }

      return oldValue == newValue
    }
  )

  cogs.commit("outer") { c in c[outerFlushTrigger] = 1 }

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
  #expect(cogs.peek(value) == 3)
  #expect(cogs.queuedTurns.isEmpty)
  guard case .idle = cogs.turnPhase else {
    Issue.record("The growing queue did not drain back to idle")
    return
  }
}
