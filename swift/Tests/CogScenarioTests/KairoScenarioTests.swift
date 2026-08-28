import Cog
import CogScenarios
import CogTesting
import Testing

// COUNT-01 through COUNT-04: the Kairo diamond, deep chain, broad fan-out, and
// unstable graph run exactly as many selectors as their shapes require. Sizes
// come from the scenario's parameters, so a reduced run proves the same
// property as the upstream default. All four are cheap enough to assert here.

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

@MainActor
@Test(arguments: [(1, 1), (50, 1), (50, 50)])
func `COUNT-03 the Kairo broad graph runs both links of every arm once per turn`(
  width: Int,
  turns: Int
) {
  let scenario = CogScenario.kairoBroad(width: width, turns: turns)

  let result = scenario.run(in: Cogs.forTesting())

  // Two links per arm, every arm reached by every turn. A propagation that
  // visited a consumer once per path into it would report more here while
  // still producing the right values.
  #expect(result.actualRuns == 2 * width * (1 + turns))
  #expect(result.isExact)
  // The last arm offsets by `width - 1` and its leaf adds one.
  #expect(result.finalValue == turns + width)
}

@MainActor
@Test(arguments: [(20, 1), (20, 2), (20, 100), (1, 100)])
func `COUNT-04 the Kairo unstable graph costs one speculative run per flipped edge`(
  iterations: Int,
  turns: Int
) {
  let scenario = CogScenario.kairoUnstable(iterations: iterations, turns: turns)

  let result = scenario.run(in: Cogs.forTesting())

  // The first settle has no recorded dependency set, so it costs the sum and
  // the one branch it reads. Every changed turn afterwards also settles the
  // branch recorded last time, which this run will drop. That is the price of
  // scheduling known parents first to keep a warm deep chain off the stack.
  #expect(result.actualRuns == 2 + 3 * turns)
  #expect(result.isExact)
  // Repeated reads of one branch cost one run and `iterations` additions, so
  // `iterations` scales the arithmetic without moving the count above.
  let head = turns
  #expect(
    result.finalValue == (head.isMultiple(of: 2) ? -iterations * head : 2 * iterations * head)
  )
}
