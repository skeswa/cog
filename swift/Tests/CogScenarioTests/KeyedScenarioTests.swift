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
@Test(arguments: [(1, 1), (10, 50), (10, 500), (3, 1000)])
func `COUNT-08 key churn costs the window, never the family`(
  window: Int,
  turns: Int
) {
  let scenario = CogScenario.keyChurn(window: window, turns: turns)

  let result = scenario.run(in: Cogs.forTesting())

  // `window + 2` per turn: the previous window settles, the entering key
  // computes for the first time, and the roster runs. The family holds
  // `window + turns` keys by the end and every one of them reads the epoch
  // this turn changed, so a dropped key that stayed subscribed would show up
  // here immediately.
  #expect(result.actualRuns == (window + 1) + turns * (window + 2))
  #expect(result.isExact)

  // The roster reads `start ..< start + window` and each entry is
  // `epoch + key`, with both epoch and start equal to the turn count.
  let expectedRoster = 2 * window * turns + window * (window - 1) / 2
  #expect(result.finalValue == expectedRoster)
}

@MainActor
@Test func `COUNT-08 a longer churn costs the same per turn`() {
  // The formula alone would be satisfied by an implementation whose per-turn
  // cost grew, as long as the scenario's expectation grew with it. Stated as a
  // difference it cannot be: a thousand turns of churn over a ten-key window
  // has created a thousand and ten keys by the end, and each of the last
  // hundred turns must still cost exactly what each of the first hundred did.
  let short = CogScenario.keyChurn(window: 10, turns: 100).run(in: Cogs.forTesting())
  let long = CogScenario.keyChurn(window: 10, turns: 1000).run(in: Cogs.forTesting())

  #expect(short.isExact)
  #expect(long.isExact)
  #expect(long.actualRuns - short.actualRuns == 900 * (10 + 2))
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
