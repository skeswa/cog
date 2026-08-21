import Cog
import CogScenarios
import CogTesting
import Testing

// COUNT-05: the `dynamicBench` sweeps run exactly as many selectors as their
// generated shapes require. The six cases below are upstream's six
// configurations at test-cheap turn counts, keeping each one's distinguishing
// dimension: narrow fan-in, wide fan-in, many layers, many nodes, and a
// rewiring graph.

/// One sweep configuration, named for what it is there to stress.
nonisolated struct DynamicSweepCase: Sendable, CustomStringConvertible {
  let label: String
  let width: Int
  let layers: Int
  let sourcesPerNode: Int
  let dynamicStride: Int
  let turns: Int

  var description: String { label }

  /// Selector runs the shape costs, calculated the way the scenario derives it.
  ///
  /// Written out again here rather than read off the scenario, so a mistake in
  /// the formula has to be made twice, in two places, to pass.
  var expectedRuns: Int {
    let rowCount = layers - 1
    var perTurn = 0
    for row in 1...rowCount {
      perTurn += min(width, (row - 1) * (sourcesPerNode - 1) + sourcesPerNode)
    }
    return rowCount * width + turns * perTurn
  }
}

private nonisolated let sweeps: [DynamicSweepCase] = [
  // Upstream's narrowest fan-in: the arc widens by one node per row, so most
  // of the graph stays clean on most turns.
  .init(
    label: "10x5 fanIn2", width: 10, layers: 5, sourcesPerNode: 2, dynamicStride: 0, turns: 100),
  // Wider fan-in over more layers: the arc saturates partway down.
  .init(
    label: "10x10 fanIn6", width: 10, layers: 10, sourcesPerNode: 6, dynamicStride: 0, turns: 50),
  // Many nodes, moderate fan-in, still far from saturation at the last row.
  .init(
    label: "100x12 fanIn4", width: 100, layers: 12, sourcesPerNode: 4, dynamicStride: 0, turns: 20),
  // Wide fan-in over few layers: every node reads a quarter of the row above.
  .init(
    label: "100x5 fanIn25", width: 100, layers: 5, sourcesPerNode: 25, dynamicStride: 0, turns: 20),
  // Upstream's deep sweep, at full depth. Cog settles it upward on the first
  // read, so GRAPH-14's cold-nesting bound never applies.
  .init(
    label: "5x500 fanIn3", width: 5, layers: 500, sourcesPerNode: 3, dynamicStride: 0, turns: 5),
  // The rewiring case. `sourcesPerNode == width` saturates the arc at row 1,
  // which is what makes an exact expectation possible while edges move.
  .init(
    label: "10x6 fanIn10 dyn", width: 10, layers: 6, sourcesPerNode: 10, dynamicStride: 2, turns: 50
  ),
]

@MainActor
@Test(arguments: sweeps)
func `COUNT-05 a dynamicBench sweep runs only the arc one write reaches`(
  sweep: DynamicSweepCase
) {
  let scenario = CogScenario.dynamicSweep(
    width: sweep.width,
    layers: sweep.layers,
    sourcesPerNode: sweep.sourcesPerNode,
    dynamicStride: sweep.dynamicStride,
    turns: sweep.turns
  )

  let result = scenario.run(in: Cogs.forTesting())

  #expect(result.actualRuns == sweep.expectedRuns)
  #expect(result.isExact)
}

@MainActor
@Test func `COUNT-05 a wider fan-in reaches more of the graph per turn`() {
  // The count is not merely self-consistent: holding width, depth, and turns
  // fixed while widening the fan-in has to cost strictly more, because the arc
  // one write reaches widens faster. A scenario that reported the same number
  // for both would be counting something other than propagation.
  let narrow = CogScenario.dynamicSweep(
    width: 20, layers: 8, sourcesPerNode: 2, turns: 10
  ).run(in: Cogs.forTesting())
  let wide = CogScenario.dynamicSweep(
    width: 20, layers: 8, sourcesPerNode: 8, turns: 10
  ).run(in: Cogs.forTesting())

  #expect(narrow.isExact)
  #expect(wide.isExact)
  #expect(narrow.actualRuns < wide.actualRuns)
}
