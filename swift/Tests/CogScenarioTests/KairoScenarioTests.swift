import Cog
import CogScenarios
import CogTesting
import Testing

// COUNT-01 and COUNT-02: the Kairo diamond and deep chain run exactly as many
// selectors as their shapes require. Sizes come from the scenario's parameters,
// so a reduced run proves the same property as the upstream default — and both
// are cheap enough to assert on here.

@MainActor
@Test(arguments: [(1, 1), (5, 1), (5, 10), (5, 500)])
func `COUNT-01 the Kairo diamond settles its shared consumer once per turn`(
  width: Int,
  turns: Int
) {
  let scenario = CogScenario.kairoDiamond(width: width, turns: turns)

  let result = scenario.run(in: Cogs.forTesting())

  // One run per arm plus one for the sum, per settled turn. A push
  // implementation that woke the sum once per changed arm would report
  // `width * turns` extra runs here and identical wall-clock noise.
  #expect(result.actualRuns == (width + 1) * (1 + turns))
  #expect(result.isExact)
  // Upstream's own assertion: each arm is `head + 1`, so the sum is
  // `width * (head + 1)`. Counting runs without checking values would pass a
  // graph that ran the right number of times and computed nonsense.
  #expect(result.finalValue == width * (turns + 1))
}

@MainActor
@Test(arguments: [(1, 1), (50, 1), (50, 50)])
func `COUNT-02 the Kairo deep chain runs each link once per turn`(
  depth: Int,
  turns: Int
) {
  let scenario = CogScenario.kairoDeep(depth: depth, turns: turns)

  let result = scenario.run(in: Cogs.forTesting())

  #expect(result.actualRuns == depth * (1 + turns))
  #expect(result.isExact)
  // Each link adds one, so the tail is the head plus the chain length.
  #expect(result.finalValue == turns + depth)
}
