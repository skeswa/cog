import CogTesting
import Testing

@testable import Cog

// Internal checks for nested-turn phases, identities, revisions, and pending
// storage.

@MainActor
@Test func `TurnCompositionInfrastructure nested turns join one outer turn`() {
  let cogs = Cogs.forTesting()
  var comparisons = 0
  var flushingTurn: CogTurnID?
  let source = Cog<Int>.Manual(
    0,
    equals: { oldValue, newValue in
      comparisons += 1
      guard case .flushing(let turn) = cogs.turnPhase else {
        Issue.record("Equality did not run inside the flush boundary")
        return oldValue == newValue
      }
      flushingTurn = turn.id
      return oldValue == newValue
    }
  )

  var outerTurn: CogTurnID?
  var innerTurn: CogTurnID?

  cogs.turn(named: "outer") { c in
    guard case .accumulating(let outer) = cogs.turnPhase else {
      Issue.record("The outer body did not accumulate")
      return
    }
    outerTurn = outer.id
    #expect(outer.name == "outer")

    c[source] = 1

    cogs.turn(named: "inner") { c in
      guard case .accumulating(let inner) = cogs.turnPhase else {
        Issue.record("The inner body did not join accumulation")
        return
      }
      innerTurn = inner.id

      #expect(inner.id == outer.id)
      #expect(inner.name == "outer")
      #expect(c[source] == 1)

      c[source] = 2
      #expect(cogs.peek(source) == 0)
      #expect(cogs.arenaCore.revision == 0)
    }

    #expect(c[source] == 2)
    #expect(cogs.peek(source) == 0)
    #expect(cogs.arenaCore.revision == 0)
  }

  #expect(outerTurn != nil)
  #expect(innerTurn == outerTurn)
  #expect(flushingTurn == outerTurn)
  #expect(comparisons == 1)
  #expect(cogs.peek(source) == 2)
  #expect(cogs.arenaCore.revision > 0)
  guard case .idle = cogs.turnPhase else {
    Issue.record("The joined turn did not finish idle")
    return
  }
}

@MainActor
@Test func `TurnCompositionInfrastructure sibling turns are separate turns`() {
  let cogs = Cogs.forTesting()
  let source = Cog<Int>.Manual(0)
  var turnIDs: [CogTurnID] = []
  var turnNames: [String] = []

  cogs.turn(named: "first") { c in
    guard case .accumulating(let turn) = cogs.turnPhase else {
      Issue.record("The first sibling did not accumulate")
      return
    }
    turnIDs.append(turn.id)
    turnNames.append(turn.name)
    c[source] = 1
  }

  let firstRevision = cogs.arenaCore.revision
  #expect(cogs.peek(source) == 1)
  guard case .idle = cogs.turnPhase else {
    Issue.record("The first sibling did not finish before the second began")
    return
  }

  cogs.turn(named: "second") { c in
    guard case .accumulating(let turn) = cogs.turnPhase else {
      Issue.record("The second sibling did not accumulate")
      return
    }
    turnIDs.append(turn.id)
    turnNames.append(turn.name)
    c[source] = 2
  }

  guard turnIDs.count == 2 else {
    Issue.record("The sibling turns did not both capture a turn")
    return
  }
  #expect(turnIDs[0] != turnIDs[1])
  #expect(turnNames == ["first", "second"])
  #expect(cogs.peek(source) == 2)
  #expect(cogs.arenaCore.revision > firstRevision)
  guard case .idle = cogs.turnPhase else {
    Issue.record("The second sibling did not finish idle")
    return
  }
}
