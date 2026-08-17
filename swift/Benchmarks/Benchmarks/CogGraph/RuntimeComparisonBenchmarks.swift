import Benchmark

/// MainActor bridge used by upstream's nonisolated benchmark entry point.
@MainActor
enum RuntimeComparisonHarness {
  /// Runtime implementations available to the M6 comparison today.
  nonisolated enum Backend: String, Sendable {
    /// Whichever Cog core the root package was compiled to select.
    case cog

    /// Swift's registrar and property instrumentation without a graph layer.
    case observation
  }

  /// Builds, runs, and checks one complete comparison sample.
  static func run(_ workload: RuntimeComparisonWorkload, on backend: Backend) {
    let graph: any RuntimeComparisonGraph =
      switch backend {
      case .cog: CogRuntimeComparisonGraph()
      case .observation: RawObservationComparisonGraph()
      }
    let result = workload.run(on: graph)
    result.check()
    blackHole(result.finalValue)
    blackHole(result.actualRuns)
  }
}

/// Registers equivalent Cog and raw-Observation PERF-10 workloads.
///
/// These are whole-graph measurements: every iteration builds, drives, and
/// releases a graph. PERF-10 compares wall clock, so allocation and ARC counts
/// remain on the steady-turn and propagation benchmarks designed to isolate
/// them. M6-11c records wall clock in one pinned environment; instructions and
/// peak resident memory remain diagnostic context rather than scenario
/// promises.
let runtimeComparisonBenchmarks: @Sendable () -> Void = {
  let metrics: [BenchmarkMetric] = [.wallClock, .instructions, .peakMemoryResident]
  let reported = BenchmarkThresholds()
  let thresholds: [BenchmarkMetric: BenchmarkThresholds] = [
    .wallClock: reported,
    .instructions: reported,
    .peakMemoryResident: reported,
  ]

  for workload in RuntimeComparisonWorkload.allCases {
    for backend in [RuntimeComparisonHarness.Backend.cog, .observation] {
      Benchmark(
        "perf-10-\(backend.rawValue)-\(workload.rawValue)",
        configuration: .init(
          metrics: metrics,
          warmupIterations: 2,
          maxDuration: .seconds(3),
          thresholds: thresholds
        )
      ) { _ in
        await RuntimeComparisonHarness.run(workload, on: backend)
      }
    }
  }
}
