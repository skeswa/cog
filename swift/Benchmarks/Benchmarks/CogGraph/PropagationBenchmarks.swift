import Benchmark
internal import Cog
import CogTesting

/// The fan PERF-02 measures: one source, `fanWidth` derived consumers, all
/// read every turn.
///
/// A fan rather than a chain. Retain and release traffic during propagation is
/// a per-*node* cost, and a fan makes the node count the only thing that
/// changes between this shape and the single-consumer graph PERF-01 measures.
/// Subtracting one from the other therefore attributes ARC traffic to
/// propagation rather than to the commit boundary, which is what PERF-02 is
/// actually about — a turn has a fixed cost no matter how small the graph, and
/// that fixed cost is not propagation.
///
/// Isolated for the reason `M5-05bb` recorded — see ``GraphHarness``. One
/// context for the whole benchmark, for the reason `M5-11` recorded: tearing a
/// context down leaves cancellation work on another thread, and the counters
/// here are process-global.
@MainActor
enum PropagationHarness {
  /// Derived consumers hanging off the one source.
  ///
  /// Sixteen is enough that the per-node term dominates the fixed per-turn
  /// term, and small enough that a run stays cheap.
  static let fanWidth = 16

  /// The source every consumer reads.
  static let fanSourceCog = ManualCog<Int>(0, name: "perf.fan.source")

  /// The consumers, declared once so the shape is fixed across iterations.
  static let fanCogs: [Cog<Int>] = (0..<fanWidth).map { index in
    Cog<Int>(
      { c in c[PropagationHarness.fanSourceCog] &+ index },
      name: "perf.fan.\(index)"
    )
  }

  /// The context under measurement, created once.
  static var cogs: Cogs?

  /// Builds and fully settles the fan, outside any measured region.
  static func settle() {
    guard cogs == nil else { return }
    let context = Cogs.forTesting()
    for fanCog in fanCogs { blackHole(context[fanCog]) }
    cogs = context
  }

  /// Runs `count` turns, each propagating one write to every consumer.
  ///
  /// Tracked reads, not `peek`, for the reason ``AllocationHarness`` gives:
  /// `peek` renews `whileObserved` grace and would price the lifetime
  /// machinery instead of the propagation.
  static func runPropagatingTurns(_ count: Int) {
    guard let cogs else { return }
    for iteration in 1...max(count, 1) {
      cogs.commit(fanSourceCog, to: iteration, name: "perf.fan.turn")
      for fanCog in fanCogs { blackHole(cogs[fanCog]) }
    }
  }
}

let propagationBenchmarks: @Sendable () -> Void = {
  // PERF-02. ARC traffic is what this shape is for, so retains, releases, and
  // object allocations are the gated metrics here — the mirror image of
  // `AllocationBenchmarks`, where they are reported and ARC is not the claim.
  //
  // Gated against drift rather than against zero, for the same reason PERF-01
  // is: propagation over class states with edge arrays does ARC work by
  // construction (perf §9.1), and §5's no-ARC rule is what the data-oriented
  // core adopts in M6. The recorded numbers, and the per-node figure derived
  // from them, are in perf.md §9.6.
  let gate = BenchmarkThresholds(
    absolute: [
      .p0: 100, .p25: 100, .p50: 100, .p75: 100, .p90: 100, .p99: 100, .p100: 100,
    ]
  )
  let reported = BenchmarkThresholds()

  Benchmark(
    "perf-02-propagation",
    configuration: .init(
      metrics: [.retainCount, .releaseCount, .objectAllocCount, .mallocCountTotal, .wallClock],
      warmupIterations: 2,
      scalingFactor: .kilo,
      maxDuration: .seconds(3),
      thresholds: [
        .retainCount: gate,
        .releaseCount: gate,
        .objectAllocCount: gate,
        .mallocCountTotal: gate,
        .wallClock: reported,
      ]
    )
  ) { benchmark in
    await PropagationHarness.settle()
    let count = benchmark.scaledIterations.count
    benchmark.startMeasurement()
    await PropagationHarness.runPropagatingTurns(count)
    benchmark.stopMeasurement()
  }
}
