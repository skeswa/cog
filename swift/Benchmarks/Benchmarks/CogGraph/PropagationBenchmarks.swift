import Benchmark
internal import Cog
import CogTesting

/// The fan PERF-02 measures: one source, `fanWidth` automatic consumers, all
/// read every turn.
///
/// A fan rather than a chain. Retain and release traffic during propagation is
/// a per-*node* cost, and a fan makes the node count the only thing that
/// changes between this shape and the single-consumer graph PERF-01 measures.
/// Subtracting one from the other therefore attributes ARC traffic to
/// propagation rather than to the turn boundary, which is what PERF-02 is
/// actually about — a turn has a fixed cost no matter how small the graph, and
/// that fixed cost is not propagation.
///
/// Isolated for the reason `M5-05bb` recorded — see ``GraphHarness``. One
/// context for the whole benchmark, for the reason `M5-11` recorded: tearing a
/// context down leaves cancellation work on another thread, and the counters
/// here are process-global.
@MainActor
enum PropagationHarness {
  /// Automatic consumers hanging off the one source.
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
      cogs.turn(fanSourceCog, to: iteration, name: "perf.fan.turn")
      for fanCog in fanCogs { blackHole(cogs[fanCog]) }
    }
  }
}

/// The chain PERF-13 measures: one source pulled through `chainDepth` automatic
/// nodes, every turn.
///
/// A chain rather than a fan, because PERF-13 is about the settle *walk* — what
/// entering and leaving one node costs — and a fan settles sixteen nodes that
/// are each one hop from the source. Depth is what makes the walk deep.
///
/// The nodes are keyed so the depth is a parameter rather than sixteen
/// declarations, and so the shape matches the probe `M9-01` profiled. This is
/// deliberately **not** the Kairo deep benchmark PERF-10 compares runtimes on:
/// that one builds and releases a graph per iteration, which prices
/// construction, and this one holds a settled graph and drives turns through
/// it.
///
/// Isolated for the reason `M5-05bb` recorded; one context for the reason
/// `M5-11` recorded.
@MainActor
enum DeepChainHarness {
  /// Nodes between the source and the read.
  ///
  /// A hundred: deep enough that the per-node term dominates the fixed
  /// per-turn term by two orders of magnitude, so dividing by it gives a
  /// per-node figure that a fixed cost cannot distort.
  static let chainDepth = 100

  /// The source at the head of the chain.
  static let chainSourceCog = ManualCog<Int>(0, name: "perf.chain.source")

  /// Each node reads the one below it; node zero reads the source.
  ///
  /// Annotated, because the selector names the declaration it belongs to and
  /// inference cannot close that loop on its own.
  static let chainCogs: CogBox<Int, Int> = CogBox<Int, Int>(
    { c, depth in
      guard depth > 0 else { return c[DeepChainHarness.chainSourceCog] }
      return c[DeepChainHarness.chainCogs[depth - 1]] &+ 1
    },
    name: "perf.chain"
  )

  /// The context under measurement, created once.
  static var cogs: Cogs?

  /// Builds and fully settles the chain, outside any measured region.
  static func settle() {
    guard cogs == nil else { return }
    let context = Cogs.forTesting()
    blackHole(context[chainCogs[chainDepth]])
    cogs = context
  }

  /// Runs `count` turns, each pulling one write through the whole chain.
  static func runChainTurns(_ count: Int) {
    guard let cogs else { return }
    for iteration in 1...max(count, 1) {
      cogs.turn(chainSourceCog, to: iteration, name: "perf.chain.turn")
      blackHole(cogs[chainCogs[chainDepth]])
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
  // from them, are in `impl/benchmarks.md`.
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

  // PERF-13. What one node of a settle walk costs, which is the figure the
  // deep-shape work in M9 is aimed at. Reported per turn; `impl/benchmarks.md` divides by
  // the depth and records the per-node result, because a per-node ceiling in a
  // threshold file would silently change meaning if the depth ever moved.
  //
  // Allocations are gated at exactly zero: `M9-09` removed the per-node
  // copy-on-write that made this shape allocate once per node, and there is no
  // reason for a settled chain to allocate at all. ARC is gated against drift,
  // because it is emphatically not zero yet — §5's rule is unmet and the routes
  // that would meet it are still on issue #373.
  Benchmark(
    "perf-13-deep-chain",
    configuration: .init(
      metrics: [.retainCount, .releaseCount, .objectAllocCount, .mallocCountTotal, .wallClock],
      warmupIterations: 2,
      scalingFactor: .kilo,
      maxDuration: .seconds(3),
      thresholds: [
        .retainCount: gate,
        .releaseCount: gate,
        .objectAllocCount: BenchmarkThresholds(absolute: [.p90: 0]),
        .mallocCountTotal: BenchmarkThresholds(absolute: [.p90: 0]),
        .wallClock: reported,
      ]
    )
  ) { benchmark in
    await DeepChainHarness.settle()
    let count = benchmark.scaledIterations.count
    benchmark.startMeasurement()
    await DeepChainHarness.runChainTurns(count)
    benchmark.stopMeasurement()
  }
}
