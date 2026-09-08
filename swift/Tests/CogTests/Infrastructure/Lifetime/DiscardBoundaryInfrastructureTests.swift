import CogTesting
import Testing

@testable import Cog

// MARK: - Discarded boundary bookkeeping
//
// The Observation boundary table is index-addressed from the arena row, so
// removing an entry has to move the last one into the gap and repoint the row
// that moved. That fix-up is invisible from the public surface until it is
// wrong, at which point one state's changes would notify another state's
// reader. These tests pin the bookkeeping directly.

@MainActor
@Test func `DiscardBoundaryInfrastructure removal repoints the entry that moved`() {
  let cogs = Cogs.forTesting()
  let first = Cog<Int>.Manual({ 1 }, lifetime: .whileObserved(resetToInitial: true))
  let second = Cog<Int>.Manual({ 2 }, lifetime: .whileObserved(resetToInitial: true))
  let third = Cog<Int>.Manual({ 3 }, lifetime: .whileObserved(resetToInitial: true))

  // Three boundaries, in creation order, so removing the first is the case that
  // moves an entry rather than simply truncating the table.
  _ = cogs[first]
  _ = cogs[second]
  _ = cogs[third]
  #expect(cogs.arenaCore.observationBoundaryCount == 3)

  cogs.discard(first)
  #expect(cogs.arenaCore.observationBoundaryCount == 2)

  // The two survivors still resolve to their own boundaries. A stale index
  // would either trap here or hand back the wrong entry.
  #expect(cogs.hasObservationBoundaryForTesting(for: second))
  #expect(cogs.hasObservationBoundaryForTesting(for: third))
  #expect(!cogs.hasObservationBoundaryForTesting(for: first))

  // Their values are intact and still notify independently.
  #expect(cogs[second] == 2)
  #expect(cogs[third] == 3)

  // Removing the last entry takes the truncation path.
  cogs.discard(third)
  #expect(cogs.arenaCore.observationBoundaryCount == 1)
  #expect(cogs.hasObservationBoundaryForTesting(for: second))
  #expect(cogs[second] == 2)
}

@MainActor
@Test func `DiscardBoundaryInfrastructure a discard inside a turn waits for its flush`() {
  // Releasing a row while its values are staged or its dependents are settling
  // would tear the graph out from under active work, so a discard requested
  // during a turn becomes a later turn in the ordinary FIFO.
  let cogs = Cogs.forTesting()
  let source = Cog<Int>.Manual({ 1 }, lifetime: .whileObserved(resetToInitial: true))
  _ = cogs[source]
  #expect(cogs.arenaCore.observationBoundaryCount == 1)

  cogs.turn("write then discard") { c in
    c[source] = 5
    cogs.discard(source)
    // Still present: the discard has not run yet, and the staged write is
    // readable through the writer as usual.
    #expect(c[source] == 5)
  }

  // By the time the outer turn has drained its queue, the state is gone and its
  // next read starts over.
  #expect(cogs.arenaCore.observationBoundaryCount == 0)
  #expect(cogs.peek(source) == 1)
}
