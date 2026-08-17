internal import Cog

// The Kairo shapes from `js-reactivity-benchmark`, by Milo Mighdoll and
// contributors (https://github.com/milomg/js-reactivity-benchmark,
// `packages/core/src/benches/kairo/`). Ported rather than reinvented so Cog's
// numbers can be read beside every other library that runs them (perf §9.2).
//
// Two deliberate differences from the originals, neither of which changes what
// is counted:
//
// Upstream keeps the graph hot with an `effect` that reads the root, because in
// a pull-only library an unobserved computed may not recompute at all. A Cog
// `peek` settles every dependency it needs before returning, so reading the
// root is enough to drive the same propagation — and it keeps the scenario free
// of a UI boundary, so what the counter sees is graph work.
//
// Upstream counts effect invocations; these count selector runs, which is the
// stricter measurement. An effect firing once tells you the root settled; it
// does not tell you whether an interior cog ran twice on the way there.

extension CogScenario {
  /// Kairo's diamond: one source, `width` parallel arms, one shared consumer.
  ///
  /// The shape exists to catch the classic push mistake — running the shared
  /// consumer once per changed parent instead of once per turn. With five arms
  /// that is the difference between six runs and ten per turn, and no timing
  /// measurement would tell you which one happened.
  ///
  /// Settling costs one run per arm plus one for the sum, and every changed
  /// turn costs the same again:
  ///
  /// ```text
  /// expectedRuns = (width + 1) × (1 + turns)
  /// ```
  ///
  /// Each arm is `source + 1`, so the sum after writing `turn` is
  /// `width × (turn + 1)` — the same arithmetic upstream asserts.
  ///
  /// - Parameters:
  ///   - width: Parallel arms between the source and the shared consumer.
  ///     Defaults to upstream's 5.
  ///   - turns: Changing turns after the first read. Defaults to upstream's
  ///     500.
  ///   - layout: The value-reference layout to build with. This shape is
  ///     keyless, so it only travels with the result.
  public static func kairoDiamond(
    width: Int = 5,
    turns: Int = 500,
    layout: CogValueReferenceLayout = .inline
  ) -> CogScenario {
    CogScenario(
      name: "COUNT-01-KairoDiamond",
      layout: layout,
      expectedRuns: (width + 1) * (1 + turns)
    ) { cogs, counter in
      let sourceCog = ManualCog<Int>(0, name: "kairo.diamond.head")
      let armCogs = (0..<width).map { arm in
        Cog<Int>(
          { c in
            counter.record()
            return c[sourceCog] + 1
          },
          name: "kairo.diamond.arm.\(arm)"
        )
      }
      let sumCog = Cog<Int>(
        { c in
          counter.record()
          return armCogs.reduce(0) { total, armCog in total + c[armCog] }
        },
        name: "kairo.diamond.sum"
      )

      var sum = cogs.peek(sumCog)
      for turn in 1...max(turns, 1) where turns > 0 {
        cogs.commit("kairo.diamond.turn") { c in c[sourceCog] = turn }
        sum = cogs.peek(sumCog)
      }
      return sum
    }
  }

  /// Kairo's deep propagation: a straight chain of `depth` derived cogs.
  ///
  /// Where the diamond catches redundant work across a fan-in, this catches it
  /// along a chain, and it is the shape that punishes a recursive settle: the
  /// explicit stack has to walk fifty links without growing the call stack.
  ///
  /// Every link runs once per settle, and once per changed turn:
  ///
  /// ```text
  /// expectedRuns = depth × (1 + turns)
  /// ```
  ///
  /// Each link adds one, so the tail after writing `turn` is `turn + depth`,
  /// matching upstream's assertion.
  ///
  /// - Parameters:
  ///   - depth: Links in the chain. Defaults to upstream's 50.
  ///   - turns: Changing turns after the first read. Defaults to upstream's 50.
  ///   - layout: The value-reference layout to build with. This shape is
  ///     keyless, so it only travels with the result.
  public static func kairoDeep(
    depth: Int = 50,
    turns: Int = 50,
    layout: CogValueReferenceLayout = .inline
  ) -> CogScenario {
    CogScenario(
      name: "COUNT-02-KairoDeep",
      layout: layout,
      expectedRuns: depth * (1 + turns)
    ) { cogs, counter in
      let sourceCog = ManualCog<Int>(0, name: "kairo.deep.head")
      // Flat ownership, for the reason GRAPH-03 gives: if each link's selector
      // captured the link below it by value, the descriptors would form a
      // chain that ARC releases recursively, and the scenario would crash on
      // teardown at depths the graph itself settles fine. Every link instead
      // reads the shared storage by index, so releasing the chain is a flat
      // array teardown. `unowned` because the storage outlives every selector
      // that reads it — it owns them.
      let storage = KairoDeepChain()
      storage.linkCogs.reserveCapacity(max(depth, 1))
      for link in 0..<max(depth, 1) {
        let belowLink = link - 1
        storage.linkCogs.append(
          Cog<Int>(
            { [unowned storage] c in
              counter.record()
              guard belowLink >= 0 else { return c[sourceCog] + 1 }
              return c[storage.linkCogs[belowLink]] + 1
            },
            name: "kairo.deep.\(link)"
          )
        )
      }
      let tailCog = storage.linkCogs[storage.linkCogs.count - 1]

      var tail = cogs.peek(tailCog)
      for turn in 1...max(turns, 1) where turns > 0 {
        cogs.commit("kairo.deep.turn") { c in c[sourceCog] = turn }
        tail = cogs.peek(tailCog)
      }
      return tail
    }
  }
}

/// Flat storage for the deep chain's links.
///
/// Exists so no link's selector retains another link. See `kairoDeep`.
@MainActor
private final class KairoDeepChain {
  /// Every link, in order, owned in one place.
  var linkCogs: [Cog<Int>] = []
}
