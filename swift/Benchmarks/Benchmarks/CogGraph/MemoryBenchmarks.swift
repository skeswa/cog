import Benchmark
internal import Cog
import CogTesting

/// The thousand-state graph PERF-03 measures.
///
/// Five hundred keyed sources and five hundred keyed automatic consumers, one
/// consumer per source, all settled. A thousand states from two declarations,
/// which is how a real screen reaches that number — per-entity state comes
/// from `box[key]`, not from a thousand hand-written `let`s.
///
/// Isolated for the reason `M5-05bb` recorded — see ``GraphHarness``.
@MainActor
enum MemoryHarness {
  /// Sources, and consumers. Twice this is the state count PERF-03 names.
  static let pairCount = 500

  /// The keyed sources.
  static let _entryCogs = CogBox<Int, Int>.Manual({ 0 }, name: "perf.memory.source")

  /// One automatic consumer per key.
  static let entryCogs = CogBox<Int, Int>(
    { c, key in c[MemoryHarness._entryCogs[key]] &+ key },
    name: "perf.memory.entry"
  )

  /// The graph under measurement, held so it cannot be released mid-sample.
  static var cogs: Cogs?

  /// Builds and settles a thousand states in a fresh context.
  ///
  /// Fresh every time on purpose: this benchmark measures what a graph *costs*
  /// to hold, so building it is the work, not the setup. The previous context
  /// is released as this one replaces it.
  static func buildThousandStates() {
    let context = Cogs.forTesting()
    for key in 0..<pairCount {
      blackHole(context.peek(_entryCogs[key]))
      blackHole(context[entryCogs[key]])
    }
    cogs = context
  }

  /// Releases the graph, so a later benchmark does not measure it.
  static func release() {
    cogs = nil
  }
}

let memoryBenchmarks: @Sendable () -> Void = {
  // PERF-03. Resident-memory *delta*, not absolute resident memory: the
  // absolute figure is dominated by the process the benchmark runs inside, and
  // would move with the harness rather than with Cog.
  //
  // No counting metrics, per `M5-11`'s rule — this benchmark builds and
  // releases a context every iteration, so its measured region is not
  // quiescent and process-global counters would attribute its teardown to
  // whatever ran next.
  Benchmark(
    "perf-03-thousand-state-memory",
    configuration: .init(
      metrics: [.peakMemoryResidentDelta, .peakMemoryResident, .wallClock],
      warmupIterations: 2,
      maxDuration: .seconds(3),
      thresholds: [
        // One mebibyte of drift, in bytes. Unlike the allocation counts, this
        // metric genuinely has a distribution: resident memory is *sampled*
        // and page-granular, not counted, and the delta only grows on the
        // iterations where the peak actually advances. Measured across five
        // runs, p50 spanned 869–1,279 KB and p100 spanned 1,278–1,556 KB, so a
        // mebibyte is about two and a half times the worst spread observed —
        // wide enough never to cry wolf, narrow enough that a graph which grew
        // to twice its footprint fails.
        //
        // p0 is deliberately absent: it reads zero on every run, because after
        // the first build the allocator already holds the pages and resident
        // memory stops growing. A threshold on it would be a threshold on
        // nothing.
        .peakMemoryResidentDelta: BenchmarkThresholds(
          absolute: [
            .p25: 1_048_576, .p50: 1_048_576, .p75: 1_048_576, .p90: 1_048_576,
            .p99: 1_048_576, .p100: 1_048_576,
          ]
        ),
        .peakMemoryResident: BenchmarkThresholds(),
        .wallClock: BenchmarkThresholds(),
      ]
    )
  ) { benchmark in
    benchmark.startMeasurement()
    await MemoryHarness.buildThousandStates()
    benchmark.stopMeasurement()
    await MemoryHarness.release()
  }
}
