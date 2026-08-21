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
  public static func kairoDiamond(
    width: Int = 5,
    turns: Int = 500
  ) -> CogScenario {
    CogScenario(
      name: "COUNT-01-KairoDiamond",
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
        cogs.turn("kairo.diamond.turn") { c in c[sourceCog] = turn }
        sum = cogs.peek(sumCog)
      }
      return sum
    }
  }

  /// Kairo's deep propagation: a straight chain of `depth` automatic cogs.
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
  public static func kairoDeep(
    depth: Int = 50,
    turns: Int = 50
  ) -> CogScenario {
    CogScenario(
      name: "COUNT-02-KairoDeep",
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
        cogs.turn("kairo.deep.turn") { c in c[sourceCog] = turn }
        tail = cogs.peek(tailCog)
      }
      return tail
    }
  }

  /// Kairo's broad propagation: `width` independent two-link arms off one
  /// source, every one of them read every turn.
  ///
  /// The diamond fans in and the deep chain runs long; this one runs *wide*.
  /// Upstream keeps an effect on every arm, so one write has to reach fifty
  /// live consumers, and the shape is what catches a propagation that walks
  /// the subscriber set more than once per consumer — a mistake the diamond
  /// hides, because there the duplicate arrivals collapse at a single sink.
  ///
  /// Each arm is two links, both of which the source's change reaches, so a
  /// settle costs two runs per arm and every changed turn costs the same
  /// again:
  ///
  /// ```text
  /// expectedRuns = 2 × width × (1 + turns)
  /// ```
  ///
  /// The `arm`th offset is `source + arm` and its leaf adds one, so the last
  /// leaf after writing `turn` is `turn + width` — the `i + 50` upstream
  /// asserts at its default width.
  ///
  /// Unlike the diamond there is no single sink to read, so the scenario peeks
  /// every leaf, which is what upstream's fifty effects do. Reading only the
  /// last one would settle one arm and leave the other forty-nine cold, and
  /// the count would then be about a chain rather than about breadth.
  ///
  /// - Parameters:
  ///   - width: Independent arms hanging off the source. Defaults to
  ///     upstream's 50.
  ///   - turns: Changing turns after the first read. Defaults to upstream's
  ///     50.
  public static func kairoBroad(
    width: Int = 50,
    turns: Int = 50
  ) -> CogScenario {
    CogScenario(
      name: "COUNT-03-KairoBroad",
      expectedRuns: 2 * width * (1 + turns)
    ) { cogs, counter in
      let sourceCog = ManualCog<Int>(0, name: "kairo.broad.head")
      // Two links per arm, and the leaf captures only its own offset, so the
      // arms stay independent of each other. No flat storage is needed here
      // the way `kairoDeep` needs it: an arm is two links deep, not fifty, so
      // releasing one cannot recurse.
      let leafCogs = (0..<width).map { arm in
        let offsetCog = Cog<Int>(
          { c in
            counter.record()
            return c[sourceCog] + arm
          },
          name: "kairo.broad.offset.\(arm)"
        )
        return Cog<Int>(
          { c in
            counter.record()
            return c[offsetCog] + 1
          },
          name: "kairo.broad.leaf.\(arm)"
        )
      }

      var last = width
      for leafCog in leafCogs { last = cogs.peek(leafCog) }
      for turn in 1...max(turns, 1) where turns > 0 {
        cogs.turn("kairo.broad.turn") { c in c[sourceCog] = turn }
        for leafCog in leafCogs { last = cogs.peek(leafCog) }
      }
      return last
    }
  }

  /// Kairo's unstable graph: a consumer whose dependency set flips every turn.
  ///
  /// Upstream calls this the worst case, and it is the only ported shape where
  /// the graph's *edges* change rather than just its values. The sum reads the
  /// source's parity and then reads `double` or `inverse` accordingly, so one
  /// of the two branches is a dependency this turn and dead weight the next.
  ///
  /// Three selectors run per changed turn, not two, and the third is not a
  /// mistake:
  ///
  /// ```text
  /// expectedRuns = 2 + 3 × turns
  /// ```
  ///
  /// Settling a consumer schedules the dependencies it recorded *last* time
  /// before rerunning it, which is exactly what keeps a warm deep chain
  /// iterative instead of nesting one call frame per link (see `settle` and
  /// GRAPH-14). When the recorded set is still right — every other ported
  /// shape — that scheduling costs nothing. Here it settles the branch the
  /// next run is about to drop, and the branch that run actually reads is
  /// pulled during it. So a changed turn costs the stale branch, the fresh
  /// branch, and the sum; only the first settle, which has no recorded set
  /// yet, costs two.
  ///
  /// Trading one speculative run per flipped edge for a call stack that does
  /// not grow with graph depth is the deliberate choice. The count is here so
  /// that trade stays exactly one run — a regression that recomputed both
  /// branches, or rescheduled per read rather than per settle, would show up
  /// as `iterations` extra runs rather than one.
  ///
  /// Each of the `iterations` reads adds the same branch value, so the sum is
  /// `2 × iterations × head` on an odd head and `-iterations × head` on an
  /// even one — 40 after `head = 1` at upstream's default, which is upstream's
  /// own assertion.
  ///
  /// - Parameters:
  ///   - iterations: Reads of the selected branch inside one run. Defaults to
  ///     upstream's 20. Repeated reads of one cog cost one run, so this scales
  ///     the arithmetic and not the expectation.
  ///   - turns: Changing turns after the first read. Defaults to upstream's
  ///     100.
  public static func kairoUnstable(
    iterations: Int = 20,
    turns: Int = 100
  ) -> CogScenario {
    CogScenario(
      name: "COUNT-04-KairoUnstable",
      expectedRuns: 2 + 3 * turns
    ) { cogs, counter in
      let sourceCog = ManualCog<Int>(0, name: "kairo.unstable.head")
      let doubleCog = Cog<Int>(
        { c in
          counter.record()
          return c[sourceCog] * 2
        },
        name: "kairo.unstable.double"
      )
      let inverseCog = Cog<Int>(
        { c in
          counter.record()
          return -c[sourceCog]
        },
        name: "kairo.unstable.inverse"
      )
      let sumCog = Cog<Int>(
        { c in
          counter.record()
          let head = c[sourceCog]
          var total = 0
          for _ in 0..<iterations {
            total += head.isMultiple(of: 2) ? c[inverseCog] : c[doubleCog]
          }
          return total
        },
        name: "kairo.unstable.sum"
      )

      var total = cogs.peek(sumCog)
      for turn in 1...max(turns, 1) where turns > 0 {
        cogs.turn("kairo.unstable.turn") { c in c[sourceCog] = turn }
        total = cogs.peek(sumCog)
      }
      return total
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
