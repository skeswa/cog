internal import Cog

extension CogScenario {
  /// The smallest shape that can catch duplicate work: one diamond, driven for
  /// `turns` turns.
  ///
  /// A source feeds two automatic cogs, and a third reads both. It is the
  /// shape a naive push implementation gets wrong — the shared consumer runs
  /// twice per turn, once per changed parent — so a harness that cannot fail
  /// on this one cannot be trusted on the ported cases either.
  ///
  /// The expectation is arithmetic, not observation. Settling the diamond
  /// costs one run of each of its three automatic cogs, and every turn that
  /// changes the source costs the same three again:
  ///
  /// ```text
  /// expectedRuns = 3 × (1 + turns)
  /// ```
  ///
  /// Each turn writes a distinct value, so equality gating never suppresses a
  /// wave and the arithmetic stays exact.
  ///
  /// - Parameters:
  ///   - turns: How many changing turns to run after the first read.
  ///     Defaults to a small count because reduced sizes are legitimate here:
  ///     the expected count derives from this parameter, so a short run proves
  ///     the same property as a long one.
  /// - Returns: A runnable scenario named `M5ScenarioSentinel`.
  public static func sentinel(turns: Int = 4) -> CogScenario {
    CogScenario(
      name: "M5ScenarioSentinel",
      expectedRuns: 3 * (1 + turns)
    ) { cogs, counter in
      let sourceCog = Cog<Int>.Manual({ 0 }, name: "sentinel.source")
      let leftCog = Cog<Int>(
        { c in
          counter.record()
          return c[sourceCog] + 1
        },
        name: "sentinel.left"
      )
      let rightCog = Cog<Int>(
        { c in
          counter.record()
          return c[sourceCog] + 2
        },
        name: "sentinel.right"
      )
      let sumCog = Cog<Int>(
        { c in
          counter.record()
          return c[leftCog] + c[rightCog]
        },
        name: "sentinel.sum"
      )

      // The first read settles all three. Reading through `peek` keeps the
      // scenario free of a UI boundary, so what is counted is graph work.
      var sum = cogs.peek(sumCog)

      for turn in 1...max(turns, 1) where turns > 0 {
        cogs.turn("sentinel.turn") { c in c[sourceCog] = turn }
        sum = cogs.peek(sumCog)
      }
      return sum
    }
  }
}
