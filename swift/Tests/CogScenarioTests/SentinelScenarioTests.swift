import Cog
import CogScenarios
import CogTesting
import Testing

// The run-count suite asserts `actual == expected` as ordinary tests, so
// duplicate work fails CI regardless of timing noise (plan M5). This file is
// the harness proving itself on the sentinel before the ported cases arrive.

@MainActor
@Test(arguments: [0, 1, 4, 9])
func `M5ScenarioSentinel costs exactly three runs per settled turn`(turns: Int) {
  let scenario = CogScenario.sentinel(turns: turns)

  let result = scenario.run(in: Cogs.forTesting())

  // Two-sided, and stated as the arithmetic rather than a literal: too many
  // runs is the duplicate work this suite exists to catch, and too few means
  // the scenario never drove the graph it claims to.
  #expect(result.actualRuns == 3 * (1 + turns))
  #expect(result.expectedRuns == 3 * (1 + turns))
  #expect(result.isExact)
}

@MainActor
@Test func `M5ScenarioSentinel settles its shared consumer once per turn`() {
  // The sentinel is a diamond, so this is the property that distinguishes a
  // lazy pull from a naive push: the shared consumer must run once per turn,
  // not once per changed parent. Four runs per turn would still look fine on
  // a stopwatch.
  let oneTurn = CogScenario.sentinel(turns: 1).run(in: Cogs.forTesting())
  let twoTurns = CogScenario.sentinel(turns: 2).run(in: Cogs.forTesting())

  #expect(twoTurns.actualRuns - oneTurn.actualRuns == 3)
}

@MainActor
@Test func `M5ScenarioSentinel starts cold in each context`() {
  // Every run must build its graph from nothing. A scenario reused against a
  // warm context would skip the first settle and quietly undercount, which
  // would make every later comparison in this suite optimistic.
  let scenario = CogScenario.sentinel(turns: 2)

  let first = scenario.run(in: Cogs.forTesting())
  let second = scenario.run(in: Cogs.forTesting())

  #expect(first == second)
  #expect(first.isExact)
}
