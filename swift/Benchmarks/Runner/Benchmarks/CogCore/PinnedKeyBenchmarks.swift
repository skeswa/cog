import Benchmark
internal import Cog
import CogTesting

/// Keyed states the UI once read and no longer shows, and the one key it still
/// writes.
///
/// This is the shape PERF-07 is about. A screen scrolls, a hundred rows come
/// and go, and every row it ever displayed left an Observation boundary pinned
/// to the app context (§5.3, perf §6). The question is what those pinned keys
/// cost on a turn that has nothing to do with them.
///
/// The measured region writes **one** key and reads **that** key. Everything
/// else in the family is pinned and untouched, so any per-turn cost that scales
/// with `pinnedKeyCount` is a flush walking boundaries it has no business
/// walking.
///
/// Quiescent by construction, so the counting metrics `M5-11` restricts are
/// safe here: sources have `.app` lifetime and the pinned keys are *observed*
/// rather than peeked, so nothing owns a grace sleeper.
///
/// Isolated for the reason `M5-05bb` recorded — see ``GraphHarness``.
@MainActor
enum PinnedKeyHarness {
  /// The keyed source a turn writes.
  static let _rowCogs = CogBox<Int, Int>.Manual({ 0 }, name: "perf.pinned.source")

  /// One automatic consumer per row, so a write actually propagates to a
  /// boundary rather than stopping at the source.
  static let rowCogs = CogBox<Int, Int>(
    { c, key in c[PinnedKeyHarness._rowCogs[key]] &+ key },
    name: "perf.pinned.row"
  )

  /// The key every turn writes. Never released, never one of the extras.
  static let liveKey = 0

  /// Contexts, one per pinned-key count, built once and kept.
  static var contexts: [Int: Cogs] = [:]

  /// Builds a context with `pinnedKeyCount` rows pinned by a UI read.
  ///
  /// Once per count, not once per iteration — tearing a context down leaves
  /// cancellation on another thread, and these counters are process-global
  /// (`M5-11`).
  ///
  /// - Parameter pinnedKeyCount: Rows the UI reads once and then forgets. The
  ///   live key is always among them, so the two shapes differ only in how many
  ///   *extra* boundaries exist.
  static func settle(pinnedKeyCount: Int) {
    guard contexts[pinnedKeyCount] == nil else { return }
    let context = Cogs.forTesting()
    for key in 0..<max(pinnedKeyCount, 1) {
      blackHole(context[rowCogs[key]])
    }
    contexts[pinnedKeyCount] = context
  }

  /// Runs `count` turns against the one live key, with the rest pinned.
  ///
  /// - Parameters:
  ///   - count: Turns to run.
  ///   - pinnedKeyCount: Which prepared context to use.
  static func runLiveKeyTurns(_ count: Int, pinnedKeyCount: Int) {
    guard let cogs = contexts[pinnedKeyCount] else { return }
    for iteration in 1...max(count, 1) {
      cogs.turn(_rowCogs[liveKey], to: iteration, name: "perf.pinned.turn")
      blackHole(cogs[rowCogs[liveKey]])
    }
  }
}

let pinnedKeyBenchmarks: @Sendable () -> Void = {
  // PERF-07. Two shapes, identical but for how many pinned keys sit beside the
  // one being written, so the difference between them *is* the pinned-key cost.
  // A single number could not say that: a turn costs what it costs, and only a
  // comparison separates the part that scales with the family.
  let gate = BenchmarkThresholds(
    absolute: [
      .p0: 100, .p25: 100, .p50: 100, .p75: 100, .p90: 100, .p99: 100, .p100: 100,
    ]
  )
  let metrics: [BenchmarkMetric] = [
    .retainCount, .releaseCount, .objectAllocCount, .mallocCountTotal, .wallClock,
  ]
  let thresholds: [BenchmarkMetric: BenchmarkThresholds] = [
    .retainCount: gate,
    .releaseCount: gate,
    .objectAllocCount: gate,
    .mallocCountTotal: gate,
    .wallClock: BenchmarkThresholds(),
  ]

  for pinnedKeyCount in [1, 100, 500] {
    Benchmark(
      "perf-07-pinned-keys-\(pinnedKeyCount)",
      configuration: .init(
        metrics: metrics,
        warmupIterations: 2,
        scalingFactor: .kilo,
        maxDuration: .seconds(3),
        thresholds: thresholds
      )
    ) { benchmark in
      await PinnedKeyHarness.settle(pinnedKeyCount: pinnedKeyCount)
      let count = benchmark.scaledIterations.count
      benchmark.startMeasurement()
      await PinnedKeyHarness.runLiveKeyTurns(count, pinnedKeyCount: pinnedKeyCount)
      benchmark.stopMeasurement()
    }
  }

  // PERF-11. The same turn beside one pinned key and beside a thousand. PERF-07
  // above pins the traffic against drift at three sizes; this pair exists to
  // make the *slope* the thing under test, because O(pinned keys) is a claim
  // about shape and no single number can carry it. `M9-06` turns the static
  // ceiling that holds the thousand-key shape to the one-key cost.
  // The thousand-key shape carries a published p90 ceiling rather than a drift
  // tolerance, because the claim is absolute: a turn beside a thousand pinned
  // keys costs what a turn beside one costs. The ceiling sits just above the
  // one-key measurement `M9-06` recorded, so a returning slope fails while it
  // is still one key wide rather than after it has grown into the noise.
  //
  // **In raw sums, not the per-operation figures the report prints.** These
  // benchmarks scale by `.kilo`, so the 71 retains a one-key turn shows in the
  // table are 71,000 here, and a ceiling written as 90 would gate nothing while
  // looking like it gated everything. `M9-06` found this the way `M5-11` found
  // it for baselines: by watching a deliberately impossible ceiling pass.
  // The one-key shape is also the **keyed steady turn**: the graph PERF-01
  // measures — a manual source, one automatic consumer reading it, one tracked
  // read — with every reference keyed. The pair is therefore the only
  // measurement of what keying itself costs, and nothing gated it until a
  // 2026-08-24 comparison priced it at 2.18x the keyless turn ([E13], with the
  // call-site attribution beside it in `impl/perf.md`). These ceilings
  // hold that price. Allocations are exactly zero at the gated percentile,
  // because a keyed turn allocates nothing for the same reason a keyless one
  // does and a claim of nothing is checkable exactly. ARC sits just above the
  // measured 27 retains and 34 releases per turn: tight enough that restoring
  // a per-turn record or slot lookup fails it — each costs two pairs — and
  // loose enough to survive the couple of pairs an inlining change can move
  // when the Xcode pin advances.
  //
  // Raw sums, like the slope ceilings below.
  let keyedTurnAllocation = BenchmarkThresholds(
    absolute: [
      .p0: 100, .p25: 100, .p50: 100, .p75: 100, .p90: 0, .p99: 100, .p100: 100,
    ]
  )
  let keyedTurnThresholds: [BenchmarkMetric: BenchmarkThresholds] = [
    .retainCount: BenchmarkThresholds(absolute: [.p90: 30_000]),
    .releaseCount: BenchmarkThresholds(absolute: [.p90: 38_000]),
    .objectAllocCount: keyedTurnAllocation,
    .mallocCountTotal: keyedTurnAllocation,
    .wallClock: BenchmarkThresholds(),
  ]

  let slopeThresholds: [BenchmarkMetric: BenchmarkThresholds] = [
    .retainCount: BenchmarkThresholds(absolute: [.p90: 90_000]),
    .releaseCount: BenchmarkThresholds(absolute: [.p90: 110_000]),
    .objectAllocCount: gate,
    .mallocCountTotal: gate,
    .wallClock: BenchmarkThresholds(),
  ]

  for pinnedKeyCount in [1, 1000] {
    Benchmark(
      "perf-11-pinned-key-slope-\(pinnedKeyCount)",
      configuration: .init(
        metrics: metrics,
        warmupIterations: 2,
        scalingFactor: .kilo,
        maxDuration: .seconds(3),
        thresholds: pinnedKeyCount == 1 ? keyedTurnThresholds : slopeThresholds
      )
    ) { benchmark in
      await PinnedKeyHarness.settle(pinnedKeyCount: pinnedKeyCount)
      let count = benchmark.scaledIterations.count
      benchmark.startMeasurement()
      await PinnedKeyHarness.runLiveKeyTurns(count, pinnedKeyCount: pinnedKeyCount)
      benchmark.stopMeasurement()
    }
  }
}
