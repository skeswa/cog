import Benchmark
import CogScenarios

/// Registers the PERF-08 keyed workloads on the selected inline layout.
///
/// Both shapes come from `_CogScenarios`, so the benchmark retains the same
/// exact run-count assertions as COUNT-07 and COUNT-08. Each iteration creates
/// and releases a context, which can leave cancelled lifetime work completing
/// after the measured region. M5-11 therefore excludes process-global malloc
/// and ARC counters here; wall clock, instructions, and peak resident memory
/// remain valid whole-process measurements. The benchmark record preserves the
/// three-layout comparison that selected this representation.
let valueReferenceBenchmarks: @Sendable () -> Void = {
  let metrics: [BenchmarkMetric] = [.wallClock, .instructions, .peakMemoryResident]
  let reported = BenchmarkThresholds()
  let thresholds: [BenchmarkMetric: BenchmarkThresholds] = [
    .wallClock: reported,
    .instructions: reported,
    .peakMemoryResident: reported,
  ]

  Benchmark(
    "perf-08-keyed-diamond",
    configuration: .init(
      metrics: metrics,
      warmupIterations: 2,
      maxDuration: .seconds(3),
      thresholds: thresholds
    )
  ) { _ in
    await GraphHarness.run(.keyedDiamond(keys: 100, width: 5, turns: 500))
  }

  Benchmark(
    "perf-08-key-churn",
    configuration: .init(
      metrics: metrics,
      warmupIterations: 2,
      maxDuration: .seconds(3),
      thresholds: thresholds
    )
  ) { _ in
    await GraphHarness.run(.keyChurn(window: 10, turns: 500))
  }
}
