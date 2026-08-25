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
  static let _counterCog = Cog<Int>.Manual({ 0 }, name: "perf.counter")

  /// One automatic consumer, so a turn actually propagates.
  static let doubledCog = Cog<Int>(
    { c in c[AllocationHarness._counterCog] * 2 },
    name: "perf.doubled"
  )

  /// A keyed source, for the `box[key]` value-reference measurement.
  static let _keyedCogs = CogBox<Int, Int>.Manual({ 0 }, name: "perf.keyed")

  /// The context under measurement, created once per benchmark setup.
  static var cogs: Cogs?

  /// Builds and fully settles the graph once, outside any measured region.
  ///
  /// Settling is what makes the measured region *steady*: the first read of a
  /// automatic cog computes it, and computing is not what PERF-01 is about.
  ///
  /// Once, not once per iteration, and that is load-bearing twice over. A
  /// steady turn is "same graph shape, new values", so a benchmark that built
  /// a fresh context each time would be measuring construction in its setup.
  /// And tearing a context down is not instantaneous — releasing one cancels
  /// whatever it still owns, and that cancellation completes on another thread
  /// shortly afterwards. Malloc and ARC counting is process-global, so a
  /// thousand context teardowns would keep dropping allocations into whichever
  /// benchmark happened to be measuring next (`M5-11`).
  static func settle() {
    guard cogs == nil else { return }
    let context = Cogs.forTesting()
    blackHole(context[doubledCog])
    blackHole(context.peek(_keyedCogs[0]))
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
      cogs.turn(_counterCog, to: iteration, name: "perf.turn")
      blackHole(cogs[doubledCog])
    }
  }

  /// Builds `count` keyed value references and throws them away.
  ///
  /// `box[key]` names a state; it does not reach one. The claim is that naming
  /// is free, which is why this loop touches no context at all.
  static func makeValueReferences(_ count: Int) {
    for key in 1...max(count, 1) {
      blackHole(_keyedCogs[key & 0x3])
    }
  }

  /// Allocates `count` times, on purpose.
  ///
  /// The witness. `M5-05bb` found that a benchmark run with the malloc
  /// interposer disabled reports `mallocCountTotal == 0` for a workload that
  /// demonstrably allocates — so a suite whose every threshold is zero passes
  /// just as happily when nothing is being measured at all. This benchmark is
  /// the control: it must always report a large non-zero malloc count, and
  /// `mise run bench:baseline:check` asserts that floor before it compares
  /// anything, because upstream thresholds cannot express a floor themselves.
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

/// How far an allocation count may drift from its baseline before the gate
/// fires, at every reported percentile.
///
/// Two things about upstream's thresholds are easy to get wrong, and `M5-11`
/// got both wrong first and then measured its way out.
///
/// They are **tolerances on the difference from a baseline**, not ceilings on
/// a value, despite being spelled `absolute`. Confirmed empirically: a
/// "ceiling" tightened below the measured cost left the check green. Absolute
/// ceilings are a different command — `thresholds check` against static
/// threshold files — and those belong to `M6-11d` with the timing gates.
///
/// They compare **raw sums, not the scaled per-operation figures the table
/// prints**. These benchmarks scale by `.kilo`, so the seven mallocs a steady
/// turn shows in the report are 7,000 in a threshold comparison, and one extra
/// allocation per operation is a drift of 1,000.
///
/// That second fact is what makes this number chooseable rather than guessed.
/// Process-global malloc counting is reliable, upstream says, "only for
/// single-threaded benchmarks with quiescent background allocation", and this
/// process is not quiescent: across forty-plus measured runs, strays appear at
/// **two raw allocations**, at any percentile, in roughly one run in seven.
/// Meanwhile the smallest regression that could possibly matter — one
/// allocation added per operation — is **1,000**.
///
/// So the two populations are three orders of magnitude apart, and 100 sits
/// between them with room on both sides: fifty times the largest noise ever
/// observed, and a tenth of the smallest real regression. A tolerance of zero
/// is the tempting choice and the wrong one; it failed roughly one run in
/// seven, and a gate that cries wolf teaches everyone to rerun.
///
/// The absolute numbers this pins against live in `impl/perf.md` — that a steady
/// turn costs seven mallocs and `box[key]` costs none.
private func allocationDrift(exactP90: Bool = false) -> BenchmarkThresholds {
  let tolerance = 100
  return BenchmarkThresholds(
    absolute: [
      .p0: tolerance, .p25: tolerance, .p50: tolerance, .p75: tolerance,
      .p90: exactP90 ? 0 : tolerance,
      .p99: tolerance, .p100: tolerance,
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

  // PERF-01, which also owns the retired PERF-12's shared-machinery zero.
  // A steady turn costs nothing, at every percentile.
  //
  // It cost seven mallocs and seven object allocations for most of the
  // project's life, and this benchmark was pinned against drift because zero
  // was a target no shipping core had met. M9 met it in shared machinery
  // rather than by swapping representation: `M9-09` reused two buffers,
  // `M9-07` stopped boxing a single write into two escaping closures, and
  // `M9-08` replaced the per-turn object and identity with a reused buffer and
  // an integer token. The gate is exact now, for the same reason PERF-06's is:
  // a claim of nothing is checkable exactly, and a tolerance around nothing
  // would only hide the first allocation to come back.
  Benchmark(
    "perf-01-steady-turn",
    configuration: .init(
      metrics: metrics,
      warmupIterations: 2,
      scalingFactor: .kilo,
      maxDuration: .seconds(3),
      thresholds: ungated.merging([
        .mallocCountTotal: allocationDrift(exactP90: true),
        .objectAllocCount: allocationDrift(exactP90: true),
      ]) { _, gate in gate }
    )
  ) { benchmark in
    await AllocationHarness.settle()
    let count = benchmark.scaledIterations.count
    benchmark.startMeasurement()
    await AllocationHarness.runSteadyTurns(count)
    benchmark.stopMeasurement()
  }

  // PERF-06. Measured at zero, exactly as the scenario words it, at every
  // percentile. The published static p90 reference is zero, and p90's
  // tolerance is also zero, so the CI gate retains the exact zero-malloc
  // requirement. Other percentiles keep the baseline-only noise tolerance;
  // the static gate reads p90 exclusively.
  Benchmark(
    "perf-06-value-reference",
    configuration: .init(
      metrics: metrics,
      warmupIterations: 2,
      scalingFactor: .kilo,
      maxDuration: .seconds(3),
      thresholds: ungated.merging([
        .mallocCountTotal: allocationDrift(exactP90: true),
        .objectAllocCount: allocationDrift(exactP90: true),
      ]) { _, gate in gate }
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
