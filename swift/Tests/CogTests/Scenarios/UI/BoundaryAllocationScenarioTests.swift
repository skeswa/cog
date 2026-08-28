import Cog
import CogTesting
import Testing

// Boundary allocation is proved through the CogTesting seam — a count and a
// per-reference membership probe — never by looking at state storage, so this
// scenario survives value-reference layout and core swaps (COUNT-09 through
// COUNT-11).

@MainActor
@Test func `UI-05 only states read through the UI boundary allocate boundary objects`() {
  let cogs = Cogs.forTesting()
  let source = Cog<Int>.Manual { 2 }
  let interior = Cog<Int> { c in c[source] * 3 }
  let displayed = Cog<String> { c in "value: \(c[interior])" }

  #expect(cogs[displayed] == "value: 6")

  // The UI read settled the whole chain, but only the value the view actually
  // read pays for a boundary; interior graph states never do.
  #expect(cogs.observationBoundaryCount == 1)
  #expect(cogs.hasObservationBoundary(for: displayed))
  #expect(!cogs.hasObservationBoundary(for: interior))
  #expect(!cogs.hasObservationBoundary(for: source))

  // Reading the source through the boundary makes it exactly the second
  // boundary owner; the interior state still has none.
  #expect(cogs[source] == 2)
  #expect(cogs.observationBoundaryCount == 2)
  #expect(cogs.hasObservationBoundary(for: source))
  #expect(!cogs.hasObservationBoundary(for: interior))
}
