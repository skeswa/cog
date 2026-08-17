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
  static let rowSourceCogs = ManualCogBox<Int, Int>(0, name: "perf.pinned.source")

  /// One derived consumer per row, so a write actually propagates to a
  /// boundary rather than stopping at the source.
  static let rowCogs = CogBox<Int, Int>(
    { c, key in c[PinnedKeyHarness.rowSourceCogs[key]] &+ key },
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
      cogs.commit(rowSourceCogs[liveKey], to: iteration, name: "perf.pinned.turn")
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
}
