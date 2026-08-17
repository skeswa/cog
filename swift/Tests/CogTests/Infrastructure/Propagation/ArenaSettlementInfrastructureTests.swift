import CogTesting
import Testing

@testable import Cog

#if COG_LEG_CORE_ARENA
// Internal proof that the public vertical slice owns arena rows and versions;
// the behavior scenarios beside it remain representation-independent.

@MainActor
@Test func `ArenaSettlementInfrastructure backdates an equal middle row without class states`() {
  let cogs = Cogs.forTesting()
  let source = ManualCog<Int>(1)
  var middleRuns = 0
  var leafRuns = 0
  let middle = Cog<Bool> { c in
    middleRuns += 1
    return c[source] > 0
  }
  let leaf = Cog<String> { c in
    leafRuns += 1
    return c[middle] ? "positive" : "not positive"
  }

  #expect(cogs.peek(leaf) == "positive")
  cogs.commit { c in c[source] = 2 }
  #expect(cogs.peek(leaf) == "positive")

  // Cold allocation runs leaf → middle → source. The equal middle and skipped
  // leaf preserve revision zero in changedAt while both become checked through
  // the source's revision-one turn.
  #expect(cogs.arenaCore.arena.changedAt == [0, 0, 1])
  #expect(cogs.arenaCore.arena.checkedAt == [1, 1, 1])
  #expect(cogs.arenaCore.arena.flags == [.occupied, .occupied, .occupied])
  #expect(cogs.arenaCore.arena.rowCount == 3)
  #expect(cogs.states.isEmpty)
  #expect(middleRuns == 2)
  #expect(leafRuns == 1)
}

@MainActor
@Test func `ArenaSettlementInfrastructure recapture reuses the abandoned pool entry`() {
  let cogs = Cogs.forTesting()
  let useFirst = ManualCog<Bool>(true)
  let first = ManualCog<Int>(1)
  let second = ManualCog<Int>(2)
  var runs = 0
  let selected = Cog<Int> { c in
    runs += 1
    return c[useFirst] ? c[first] : c[second]
  }

  #expect(cogs.peek(selected) == 1)
  #expect(cogs.arenaCore.edges.entryCount == 2)
  #expect(cogs.arenaCore.edges.liveCount == 2)

  cogs.commit { c in c[useFirst] = false }
  #expect(cogs.peek(selected) == 2)
  #expect(cogs.arenaCore.edges.entryCount == 2)
  #expect(cogs.arenaCore.edges.liveCount == 2)

  cogs.commit { c in c[first] = 10 }
  #expect(cogs.peek(selected) == 2)
  #expect(runs == 2)
  #expect(cogs.states.isEmpty)
}
#endif
