import Benchmark
internal import Cog
import CogTesting

/// The graph PERF-01 and PERF-06 measure, owned on the MainActor.
///
/// Declarations are `static let` so the shape is fixed across every iteration:
/// a steady turn is "same graph shape, new values", and a benchmark that
/// rebuilt its declarations each time would be measuring construction.
///
/// Isolated for the reason `M5-05bb` recorded — see ``GraphHarness``. Every
/// entry point takes `Sendable` arguments and returns nothing.
@MainActor
enum AllocationHarness {
  /// The source a steady turn writes.
  static let counterSourceCog = ManualCog<Int>(0, name: "perf.counter")

  /// One derived consumer, so a turn actually propagates.
  static let doubledCog = Cog<Int>(
    { c in c[AllocationHarness.counterSourceCog] * 2 },
    name: "perf.doubled"
  )

  /// A keyed source, for the `box[key]` value-reference measurement.
  static let keyedSourceCogs = ManualCogBox<Int, Int>(0, name: "perf.keyed")

  /// The context under measurement, created once per benchmark setup.
  static var cogs: Cogs?

  /// Builds and fully settles the graph, outside any measured region.
  ///
  /// Settling here is what makes the measured region *steady*: the first read
  /// of a derived cog computes it, and computing is not what PERF-01 is about.
  static func settle() {
    let context = Cogs.forTesting()
    blackHole(context[doubledCog])
    blackHole(context.peek(keyedSourceCogs[0]))
    cogs = context
  }

  /// Runs `count` steady turns: one write, one tracked read, nothing new.
  ///
  /// The read is the tracked subscript rather than `peek`. That is not a
  /// convenience — a `peek` is transient demand and renews the declaration's
  /// `whileObserved` grace on every call, which costs a sleeper and is
  /// therefore a measurement of the lifetime machinery rather than of a turn.
  /// A UI read is the tracked one, and a UI read is what a steady turn serves.
  static func runSteadyTurns(_ count: Int) {
    guard let cogs else { return }
    for iteration in 1...max(count, 1) {
      cogs.commit(counterSourceCog, to: iteration, name: "perf.turn")
      blackHole(cogs[doubledCog])
    }
  }

  /// Builds `count` keyed value references and throws them away.
  ///
  /// `box[key]` names a state; it does not reach one. The claim is that naming
  /// is free, which is why this loop touches no context at all.
  static func makeValueReferences(_ count: Int) {
    for key in 1...max(count, 1) {
      blackHole(keyedSourceCogs[key & 0x3])
    }
  }

  /// Allocates `count` times, on purpose.
  ///
  /// The witness. `M5-05bb` found that a benchmark run with the malloc
  /// interposer disabled reports `mallocCountTotal == 0` for a workload that
  /// demonstrably allocates — so a suite whose every threshold is zero passes
  /// just as happily when nothing is being measured at all. This benchmark is
  /// the control: it must always report a large non-zero malloc count, and
  /// `M5-08a` is responsible for asserting that floor when it wires baselines,
  /// because upstream thresholds are upper bounds and cannot express one.
  static func allocateDeliberately(_ count: Int) {
    for iteration in 1...max(count, 1) {
      blackHole(WitnessBox(value: iteration))
    }
  }
}

/// One heap allocation, with nothing the optimizer can fold away.
private final class WitnessBox {
  let value: Int
  init(value: Int) { self.value = value }
}

/// An allocation ceiling that must hold at every reported percentile.
///
/// Allocation counts are not timings. They came back byte-identical from p0 to
/// p100 across more than a thousand samples, so there is no distribution to
/// leave headroom for and a ceiling that only bound p90 would be leaving the
/// tail unguarded for no reason.
private func allocationCeiling(_ limit: Int) -> BenchmarkThresholds {
  BenchmarkThresholds(
    absolute: [
      .p0: limit, .p25: limit, .p50: limit, .p75: limit, .p90: limit, .p99: limit,
      .p100: limit,
    ]
  )
}

let allocationBenchmarks: @Sendable () -> Void = {
  // Scaled per iteration, so the reported figure is "per steady turn" and
  // "per value reference" rather than "per thousand of them". PERF-01 and
  // PERF-06 are both statements about one operation, and a threshold reads
  // best in the same units as the claim.
  let metrics: [BenchmarkMetric] = [
    .mallocCountTotal, .objectAllocCount, .retainCount, .releaseCount, .wallClock,
  ]
  // Measured, reported, and deliberately not gated. A metric with thresholds
  // on neither side is skipped by `baseline check`, which is the right answer
  // for wall clock and ARC in M5: timing gates belong to M6 (`M6-11d`,
  // generous absolute thresholds), and upstream's default relative threshold
  // is 5% — tight enough that ordinary jitter would fail a check that has
  // nothing to say about allocations. A gate that cries wolf is worse than no
  // gate, because it teaches everyone to rerun.
  let measuredNotGated = BenchmarkThresholds()
  let ungated: [BenchmarkMetric: BenchmarkThresholds] = [
    .wallClock: measuredNotGated,
    .retainCount: measuredNotGated,
    .releaseCount: measuredNotGated,
  ]

  // PERF-01. The ceiling is the **measured** cost of a turn on the simple
  // core — seven mallocs, seven object allocations — not zero. Zero is what
  // the data-oriented core has to reach (perf.md §9.6); until it does, a
  // ceiling at the current cost is what keeps the number from drifting upward
  // unnoticed, which a zero threshold nobody can satisfy would not.
  Benchmark(
    "perf-01-steady-turn",
    configuration: .init(
      metrics: metrics,
      warmupIterations: 2,
      scalingFactor: .kilo,
      maxDuration: .seconds(3),
      thresholds: ungated.merging([
        .mallocCountTotal: allocationCeiling(7),
        .objectAllocCount: allocationCeiling(7),
      ]) { _, ceiling in ceiling }
    )
  ) { benchmark in
    await AllocationHarness.settle()
    let count = benchmark.scaledIterations.count
    benchmark.startMeasurement()
    await AllocationHarness.runSteadyTurns(count)
    benchmark.stopMeasurement()
  }

  // PERF-06. Zero, exactly as the scenario words it, and measured to be zero
  // at every percentile.
  Benchmark(
    "perf-06-value-reference",
    configuration: .init(
      metrics: metrics,
      warmupIterations: 2,
      scalingFactor: .kilo,
      maxDuration: .seconds(3),
      thresholds: ungated.merging([
        .mallocCountTotal: allocationCeiling(0),
        .objectAllocCount: allocationCeiling(0),
      ]) { _, ceiling in ceiling }
    )
  ) { benchmark in
    let count = benchmark.scaledIterations.count
    benchmark.startMeasurement()
    await AllocationHarness.makeValueReferences(count)
    benchmark.stopMeasurement()
  }

  // The control. See `allocateDeliberately`. No ceiling of its own: upstream
  // thresholds are upper bounds and what this benchmark needs is a floor, which
  // `mise run bench:baseline:check` asserts outside the harness.
  Benchmark(
    "perf-witness-allocating",
    configuration: .init(
      metrics: metrics,
      warmupIterations: 2,
      scalingFactor: .kilo,
      maxDuration: .seconds(3),
      thresholds: ungated.merging([
        .mallocCountTotal: measuredNotGated,
        .objectAllocCount: measuredNotGated,
      ]) { _, ungatedMetric in ungatedMetric }
    )
  ) { benchmark in
    let count = benchmark.scaledIterations.count
    benchmark.startMeasurement()
    await AllocationHarness.allocateDeliberately(count)
    benchmark.stopMeasurement()
  }
}
