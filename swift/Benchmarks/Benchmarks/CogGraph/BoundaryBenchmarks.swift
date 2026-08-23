import Benchmark
internal import Cog
import CogTesting

/// The graph PERF-04 measures: a thousand states, twelve of them on screen.
///
/// Nine hundred and eighty-eight keyed sources and twelve keyed consumers —
/// exactly a thousand states, and exactly twelve values a view reads. Sources
/// for the bulk on purpose: they have `.app` lifetime, so filling the graph
/// costs no grace sleepers and the measured region stays quiescent (`M5-11`).
///
/// The twelve are read through the **tracked** subscript, which is the read a
/// view performs and the only read that creates an Observation boundary. The
/// other nine hundred and eighty-eight are settled with `peek`, which is
/// deliberately not a UI read.
///
/// Isolated for the reason `M5-05bb` recorded — see ``GraphHarness``.
@MainActor
enum BoundaryHarness {
  /// States a view never reads.
  static let offscreenCount = 988

  /// Values a view reads, and so the number of boundary objects expected.
  static let onscreenCount = 12

  /// The bulk of the graph.
  static let _offscreenCogs = CogBox<Int, Int>.Manual(0, name: "perf.boundary.offscreen")

  /// The twelve a view reads.
  static let onscreenCogs = CogBox<Int, Int>(
    { c, key in c[BoundaryHarness._offscreenCogs[key]] &+ key },
    name: "perf.boundary.onscreen"
  )

  /// Builds the graph, performs twelve UI reads, and reports how many
  /// boundaries exist.
  ///
  /// The count comes from `CogTesting`'s narrow seam: a number, never the
  /// boundary objects or the states themselves, so this stayed true while the
  /// storage candidates were selected and remains true for `CompactArena`.
  ///
  /// - Returns: The Observation boundaries the context owns.
  static func countBoundaries() -> Int {
    let cogs = Cogs.forTesting()
    for key in 0..<offscreenCount {
      blackHole(cogs.peek(_offscreenCogs[key]))
    }
    for key in 0..<onscreenCount {
      blackHole(cogs[onscreenCogs[key]])
    }
    return cogs.observationBoundaryCount
  }
}

/// Boundary objects the context owns after twelve UI reads.
///
/// A custom metric because this is a *count of live objects*, which no built-in
/// metric expresses — `objectAllocCount` counts allocations over a region, and
/// what PERF-04 claims is about what survives, not about what was made.
/// Unscaled: twelve is twelve, not twelve per thousand iterations.
private let boundaryMetric = BenchmarkMetric.custom(
  "observationBoundaries",
  polarity: .prefersSmaller,
  useScalingFactor: false
)

let boundaryBenchmarks: @Sendable () -> Void = {
  // PERF-04. Gated at zero drift, because this is an exact count rather than a
  // sampled quantity: a graph that started giving every state a boundary would
  // report 1,000 where the baseline says 12, and there is no noise floor to
  // leave room for.
  //
  // Only the custom metric and wall clock. No counting metrics, per `M5-11`'s
  // rule — the context is built and dropped every iteration.
  let exact = BenchmarkThresholds(
    absolute: [.p0: 0, .p25: 0, .p50: 0, .p75: 0, .p90: 0, .p99: 0, .p100: 0]
  )

  Benchmark(
    "perf-04-lazy-boundaries",
    configuration: .init(
      metrics: [boundaryMetric, .wallClock],
      warmupIterations: 2,
      maxDuration: .seconds(2),
      thresholds: [boundaryMetric: exact, .wallClock: BenchmarkThresholds()]
    )
  ) { benchmark in
    benchmark.startMeasurement()
    let boundaries = await BoundaryHarness.countBoundaries()
    benchmark.stopMeasurement()
    benchmark.measurement(boundaryMetric, boundaries)
  }
}
