import CogTesting
import Testing

@testable import Cog

// Internal proofs that an arena-selected reaction participates in scalar
// topology directly. Public REACT scenarios remain representation-independent.

@MainActor
@Test func `ArenaReactionInfrastructure owns an indexed terminal without a class bridge`() {
  let cogs = Cogs.forTesting()
  let source = Cog<Int>.Manual(0)
  var values: [Int] = []

  let token = cogs.register(
    label: CogLabel(name: "collector", fileID: #fileID, line: #line)
  ) { c in
    values.append(c[source])
  }
  let reactionSlot = token.reaction.arenaSlot

  #expect(values == [0])
  #expect(cogs.arenaCore.arena.contains(reactionSlot))
  #expect(cogs.arenaCore.arena.descriptor[Int(reactionSlot.index)] == CogArenaStorage.noIndex)
  #expect(cogs.arenaCore.edges.liveCount == 1)

  cogs.turn { c in c[source] = 1 }

  #expect(values == [0, 1])
  #expect(cogs.arenaCore.edges.liveCount == 1)

  token.cancel()

  #expect(!cogs.arenaCore.arena.contains(reactionSlot))
  #expect(cogs.arenaCore.edges.liveCount == 0)
  #expect(cogs.reactions.isEmpty)
}

@MainActor
@Test func `ArenaReactionInfrastructure self cancellation retires capture after the body`() throws {
  let cogs = Cogs.forTesting()
  let trigger = Cog<Int>.Manual(0)
  let afterCancellation = Cog<Int>.Manual(10)
  var token: ReactionToken?
  var values: [Int] = []

  token = cogs.register(
    label: CogLabel(name: "self-cancelling", fileID: #fileID, line: #line)
  ) { c in
    let triggerValue = c[trigger]
    if triggerValue > 0 {
      token?.cancel()
      values.append(c[afterCancellation])
    }
  }
  let reactionSlot = try #require(token).reaction.arenaSlot

  #expect(cogs.arenaCore.edges.liveCount == 1)
  cogs.turn { c in c[trigger] = 1 }

  #expect(values == [10])
  #expect(token?.reaction.isCancelled == true)
  #expect(!cogs.arenaCore.arena.contains(reactionSlot))
  #expect(cogs.arenaCore.edges.liveCount == 0)
  #expect(cogs.reactions.isEmpty)
}
