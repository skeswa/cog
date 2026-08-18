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

    /// swift-state-graph's stored and memoized computed node graph.
    case stateGraph = "state-graph"
  }

  /// Builds, runs, and checks one complete comparison sample.
  static func run(_ workload: RuntimeComparisonWorkload, on backend: Backend) {
    let graph: any RuntimeComparisonGraph =
      switch backend {
      case .cog: CogRuntimeComparisonGraph()
      case .observation: RawObservationComparisonGraph()
      case .stateGraph: StateGraphRuntimeComparisonGraph()
      }
    let result = workload.run(on: graph)
    result.check()
    blackHole(result.finalValue)
    blackHole(result.actualRuns)
  }
}

/// Returns the PERF-10 p90 wall-clock ceiling, in nanoseconds.
///
/// The values are deliberately loose: each is roughly three times the slower
/// pinned p90 for that runtime and workload. Cog's row covers both the simple
/// and arena builds because this gate must remain valid whichever core M6-12a
/// selects. The static threshold files use zero as their reference point, so
/// this absolute tolerance is the one-sided ceiling: every nonnegative result
/// through the value passes, and only a slower result can fail.
private func runtimeComparisonWallClockCeiling(
  workload: RuntimeComparisonWorkload,
  backend: RuntimeComparisonHarness.Backend
) -> Int {
  switch (backend, workload) {
  case (.cog, .diamond): 20_000_000
  case (.cog, .deep): 10_000_000
  case (.cog, .broad): 40_000_000
  case (.cog, .unstable): 10_000_000
  case (.observation, .diamond): 3_000_000
  case (.observation, .deep): 1_000_000
  case (.observation, .broad): 8_000_000
  case (.observation, .unstable): 2_000_000
  case (.stateGraph, .diamond): 80_000_000
  case (.stateGraph, .deep): 50_000_000
  case (.stateGraph, .broad): 120_000_000
  case (.stateGraph, .unstable): 25_000_000
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

  for workload in RuntimeComparisonWorkload.allCases {
    for backend in [RuntimeComparisonHarness.Backend.cog, .observation, .stateGraph] {
      let wallClockCeiling = runtimeComparisonWallClockCeiling(
        workload: workload,
        backend: backend
      )
      Benchmark(
        "perf-10-\(backend.rawValue)-\(workload.rawValue)",
        configuration: .init(
          metrics: metrics,
          warmupIterations: 2,
          maxDuration: .seconds(3),
          thresholds: [
            .wallClock: BenchmarkThresholds(absolute: [.p90: wallClockCeiling]),
            .instructions: reported,
            .peakMemoryResident: reported,
          ]
        )
      ) { _ in
        await RuntimeComparisonHarness.run(workload, on: backend)
      }
    }
  }
}
