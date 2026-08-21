internal import Cog

// Cog's own additions to the ported suite (perf §9.2). The `js-reactivity-benchmark`
// cases all measure keyless graphs, because the libraries they compare have no
// keyed declarations: a per-entity graph there means one signal object per
// entity, allocated by hand.
//
// Cog does have keyed declarations — one `CogBox` names a family of states that
// `box[key]` reaches — and their whole promise is that the family behaves like
// independent graphs. That promise is exactly a run-count claim, so it belongs
// in the counted suite rather than in a timing chart. The same shape supplied
// the behavior proof while the inline value-reference layout was selected
// (perf §4).

extension CogScenario {
  /// A keyed diamond per key: one keyed source, `width` keyed arms, one keyed
  /// consumer, driven one key at a time.
  ///
  /// This is `kairoDiamond` with a key threaded through it, and the reason to
  /// run both is that they fail differently. The keyless diamond catches a
  /// consumer woken once per changed parent. This one catches a keyed
  /// declaration that behaves like one shared state — a box that invalidated
  /// every key when one key was written would still produce correct values, and
  /// would still pass every keyless count in the suite.
  ///
  /// Every turn writes exactly one key and then reads **every** key, so a key
  /// that recomputed without being written has nowhere to hide:
  ///
  /// ```text
  /// expectedRuns = (keys + turns) × (width + 1)
  /// ```
  ///
  /// `keys × (width + 1)` to settle every key's diamond once, and
  /// `width + 1` per turn — the written key's arms and its consumer, and
  /// nothing else. A box that invalidated the whole family per write would
  /// report `keys × (width + 1)` per turn instead.
  ///
  /// Each key's arms are `source + 1` and its consumer sums them, so a key
  /// last written with `value` holds `width × (value + 1)`, and a key never
  /// written holds `width`.
  ///
  /// - Parameters:
  ///   - keys: Independent keys in the family.
  ///   - width: Parallel arms between each key's source and its consumer.
  ///   - turns: Changing turns after the first read, each writing one key,
  ///     cycling through them.
  public static func keyedDiamond(
    keys: Int = 100,
    width: Int = 5,
    turns: Int = 500
  ) -> CogScenario {
    CogScenario(
      name: "COUNT-07-KeyedDiamond",
      expectedRuns: (keys + turns) * (width + 1)
    ) { cogs, counter in
      let sourceCogs = ManualCogBox<Int, Int>(0, name: "keyed.diamond.head")
      // One declaration per arm, each keyed by the whole family. Keying the arm
      // index instead would make one box hold `keys × width` states and turn a
      // per-key claim into a per-composite-key one, which is a different
      // property from the one this shape is about.
      let armCogs = (0..<width).map { arm in
        CogBox<Int, Int>(
          { c, key in
            counter.record()
            return c[sourceCogs[key]] + 1
          },
          name: "keyed.diamond.arm.\(arm)"
        )
      }
      let sumCogs = CogBox<Int, Int>(
        { c, key in
          counter.record()
          return armCogs.reduce(0) { total, armBox in total + c[armBox[key]] }
        },
        name: "keyed.diamond.sum"
      )

      // Explicitly MainActor: a nested function does not inherit the enclosing
      // closure's isolation the way a nested closure does, and the scenario
      // body runs on the MainActor in every test leg.
      @MainActor func readEveryKey() -> Int {
        var total = 0
        for key in 0..<keys { total += cogs.peek(sumCogs[key]) }
        return total
      }

      var total = readEveryKey()
      for turn in 1...max(turns, 1) where turns > 0 {
        // One key per turn, cycling. Every write moves its key by `keys`, or
        // off zero the first time, so no turn is ever gated away as equal.
        let key = turn % keys
        cogs.turn("keyed.diamond.turn") { c in c[sourceCogs[key]] = turn }
        total = readEveryKey()
      }
      return total
    }
  }

  /// Key churn: a sliding window of live keys over a family that keeps
  /// growing, with a global change every turn that every live key reads.
  ///
  /// The keyed diamond proves one key's write does not wake its siblings. This
  /// proves the harder half: a key that has fallen out of the read set stops
  /// costing anything, *even when something it reads changes*. Every turn
  /// bumps an epoch that every keyed cog reads, so a family that kept dropped
  /// keys subscribed would recompute all of them and its per-turn cost would
  /// grow without bound while the live set stayed the same size.
  ///
  /// Per turn: the window's keys settle, the one key entering the window
  /// computes for the first time, and the roster itself runs.
  ///
  /// ```text
  /// expectedRuns = (window + 1) + turns × (window + 2)
  /// ```
  ///
  /// The `window` term counts the *previous* window rather than the new one,
  /// which is why the per-turn cost is `window + 2` and not `window + 1`.
  /// Settling a consumer schedules the dependencies it recorded last time
  /// before rerunning it — the same mechanism COUNT-04 measures — so the key
  /// leaving the window settles one final time on the turn it leaves. It never
  /// runs again after that, and no key dropped earlier runs at all, which is
  /// exactly the claim: the cost is a function of the window, never of how
  /// many keys the family has ever held.
  ///
  /// The roster reads keys `start ..< start + window` and each key is
  /// `epoch + key`, so after `turns` turns it holds
  /// `2 × window × turns + window × (window − 1) / 2`.
  ///
  /// - Parameters:
  ///   - window: Live keys at any moment.
  ///   - turns: Turns after the first read. Each advances the window by one
  ///     key and bumps the epoch, so the family ends up holding
  ///     `window + turns` keys and reading `window` of them.
  public static func keyChurn(
    window: Int = 10,
    turns: Int = 500
  ) -> CogScenario {
    CogScenario(
      name: "COUNT-08-KeyChurn",
      expectedRuns: (window + 1) + turns * (window + 2)
    ) { cogs, counter in
      // Read by every key that has ever been created, so a dropped key that
      // stayed subscribed would have to recompute. Without it, "dropped keys
      // stop running" would be true of any implementation at all, because
      // nothing would be asking them to run.
      let epochSourceCog = ManualCog<Int>(0, name: "churn.epoch")
      let windowStartSourceCog = ManualCog<Int>(0, name: "churn.windowStart")
      let entryCogs = CogBox<Int, Int>(
        { c, key in
          counter.record()
          return c[epochSourceCog] + key
        },
        name: "churn.entry"
      )
      let rosterCog = Cog<Int>(
        { c in
          counter.record()
          let start = c[windowStartSourceCog]
          var total = 0
          for key in start..<(start + window) { total += c[entryCogs[key]] }
          return total
        },
        name: "churn.roster"
      )

      var roster = cogs.peek(rosterCog)
      for turn in 1...max(turns, 1) where turns > 0 {
        cogs.turn("churn.turn") { c in
          c[epochSourceCog] = turn
          c[windowStartSourceCog] = turn
        }
        roster = cogs.peek(rosterCog)
      }
      return roster
    }
  }
}
