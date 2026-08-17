import Cog
import CogScenarios
import CogTesting
import Testing

// COUNT-06: the cellx lattice runs every node exactly once to settle and
// exactly once for the turn that rewrites all four sources. Nothing is pruned
// here, by construction — the two orbits differ in every component at every
// layer — so any count other than `8 × layers` is duplicate or missed work.

/// One step of upstream's layer transform, computed here rather than read off
/// the scenario.
///
/// The scenario's arithmetic and this one have to agree for the packed value to
/// match, so a mistake in the transform must be made twice, in two places,
/// to pass.
private nonisolated func cellxStep(_ layer: [Int]) -> [Int] {
  [
    layer[1],
    layer[0] - layer[2],
    layer[1] + layer[3],
    layer[2],
  ]
}

/// Iterates the transform `layers` times from `start`.
private nonisolated func cellxEnd(from start: [Int], layers: Int) -> [Int] {
  var current = start
  for _ in 0..<layers { current = cellxStep(current) }
  return current
}

@MainActor
@Test(arguments: [1, 2, 4, 12, 13, 100])
func `COUNT-06 the cellx lattice runs every node once to settle and once per turn`(
  layers: Int
) {
  let scenario = CogScenario.cellxLattice(layers: layers)

  let result = scenario.run(in: Cogs.forTesting())

  #expect(result.actualRuns == 8 * layers)
  #expect(result.isExact)
  #expect(
    result.finalValue
      == CogScenario.packCellxValues(
        cellxEnd(from: [1, 2, 3, 4], layers: layers)
          + cellxEnd(from: [4, 3, 2, 1], layers: layers)
      )
  )
}

@MainActor
@Test(arguments: [1000, 2500])
func `COUNT-06 the cellx lattice reproduces upstream's published end values`(
  layers: Int
) {
  // Upstream asserts these exact tuples at exactly these depths. They are the
  // reason to port cellx rather than invent a lattice: a number that matches
  // another implementation's published result is evidence the shape was ported
  // and not merely inspired by.
  let scenario = CogScenario.cellxLattice(layers: layers)

  let result = scenario.run(in: Cogs.forTesting())

  #expect(result.actualRuns == 8 * layers)
  #expect(result.isExact)
  #expect(result.finalValue == CogScenario.packCellxValues([-3, -6, -2, 2, -2, -4, 2, 3]))
}
