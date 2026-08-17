internal import Cog

// Cog's own additions to the ported suite (perf §9.2). The `js-reactivity-benchmark`
// cases all measure keyless graphs, because the libraries they compare have no
// keyed declarations: a per-entity graph there means one signal object per
// entity, allocated by hand.
//
// Cog does have keyed declarations — one `CogBox` names a family of states that
// `box[key]` reaches — and their whole promise is that the family behaves like
// independent graphs. That promise is exactly a run-count claim, so it belongs
// in the counted suite rather than in a timing chart, and it is the shape whose
// physical cost depends on the value-reference layout the benchmarks will
// choose (perf §4).

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
  ///   - layout: The value-reference layout to build the keyed references
  ///     with. This is the shape that layout choice actually moves.
  public static func keyedDiamond(
    keys: Int = 100,
    width: Int = 5,
    turns: Int = 500,
    layout: CogValueReferenceLayout = .inline
  ) -> CogScenario {
    CogScenario(
      name: "COUNT-07-KeyedDiamond",
      layout: layout,
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
        cogs.commit("keyed.diamond.turn") { c in c[sourceCogs[key]] = turn }
        total = readEveryKey()
      }
      return total
    }
  }
}
