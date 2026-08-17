import Cog
import CogScenarios
import CogTesting
import Testing

// COUNT-07: a keyed diamond costs one key's worth of work per turn, however
// many keys the family holds. Every turn reads every key, so a key that
// recomputed without being written has nowhere to hide.

/// The value a key was last written with under the scenario's write schedule,
/// or zero if the schedule never reached it.
///
/// Computed here rather than read off the scenario, so a mistake in the
/// schedule has to be made twice, in two places, to pass.
private nonisolated func lastWrite(toKey key: Int, keys: Int, turns: Int) -> Int {
  var value = 0
  for turn in 1...max(turns, 1) where turns > 0 && turn % keys == key {
    value = turn
  }
  return value
}

@MainActor
@Test(arguments: [(1, 5, 10), (10, 5, 50), (50, 1, 50), (100, 5, 500)])
func `COUNT-07 a keyed diamond recomputes only the key that was written`(
  keys: Int,
  width: Int,
  turns: Int
) {
  let scenario = CogScenario.keyedDiamond(keys: keys, width: width, turns: turns)

  let result = scenario.run(in: Cogs.forTesting())

  // Settle every key once, then pay for one key per turn. A box that
  // invalidated its whole family on a single key's write would report
  // `keys × (width + 1)` per turn and still produce every correct value.
  #expect(result.actualRuns == (keys + turns) * (width + 1))
  #expect(result.isExact)

  // Each key's arms are `source + 1` and its consumer sums them.
  let expectedTotal = (0..<keys).reduce(0) { total, key in
    total + width * (lastWrite(toKey: key, keys: keys, turns: turns) + 1)
  }
  #expect(result.finalValue == expectedTotal)
}

@MainActor
@Test func `COUNT-07 a wider keyed family costs no more per turn`() {
  // The property stated as a comparison, because the formula alone could be
  // satisfied by a scenario that never grew the family. Ten keys and a hundred
  // keys driven for the same number of turns differ only by the cost of
  // settling the extra keys once — never by the per-turn cost.
  let small = CogScenario.keyedDiamond(keys: 10, width: 5, turns: 20)
    .run(in: Cogs.forTesting())
  let large = CogScenario.keyedDiamond(keys: 100, width: 5, turns: 20)
    .run(in: Cogs.forTesting())

  #expect(small.isExact)
  #expect(large.isExact)
  #expect(large.actualRuns - small.actualRuns == 90 * (5 + 1))
}
