#if DEBUG

import Cog
import CogTesting
import Testing

@MainActor
@Test func `HIST-07 queued turns land whole and in order`() {
  // A reaction chain queues turns during a flush. Each queued turn is its own
  // history entry in execution order, and every write attributes to the turn
  // that made it — entries from different turns never interleave.
  let (cogs, m) = Cogs.forTestingWithController()
  let trigger = Cog<Int>.Manual({ 0 }, name: "trigger")
  let middle = Cog<Int>.Manual({ 0 }, name: "middle")
  let leaf = Cog<Int>.Manual({ 0 }, name: "leaf")

  m.run { c in
    guard c[trigger] == 1 else { return }
    cogs.turn("chain.middle") { c in c[middle] = 1 }
  }
  m.run { c in
    guard c[middle] == 1 else { return }
    cogs.turn("chain.leaf") { c in c[leaf] = 1 }
  }

  cogs.turn("chain.start") { c in c[trigger] = 1 }

  let entries = cogs.debugHistory.entries
  let turns = entries.filter { $0.event == .turn }
  #expect(turns.map(\.name) == ["chain.start", "chain.middle", "chain.leaf"])
  #expect(turns.map(\.turn) == [1, 2, 3])

  let writes = entries.filter { $0.event == .write }
  #expect(writes.map(\.name) == ["trigger", "middle", "leaf"])
  #expect(writes.map(\.turn) == [1, 2, 3])

  // Whole means contiguous: walking history, the turn ordinal never goes
  // backward, so no queued turn's entries split another's.
  let ordinals = entries.map(\.turn)
  #expect(ordinals == ordinals.sorted())
}

#endif
