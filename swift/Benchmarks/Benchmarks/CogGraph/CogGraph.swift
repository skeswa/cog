import Benchmark
internal import Cog
import CogScenarios
import CogTesting

/// A MainActor-isolated owner for every graph these benchmarks measure.
///
/// The shim `M5-05bb` proved necessary, and the only one. `Benchmark` is not
/// `Sendable` and upstream's `benchmarks` closure is nonisolated, so a
/// measurement handle cannot cross into a MainActor region — writing
/// `await MainActor.run { benchmark.startMeasurement() }` does not compile.
/// Putting the graph behind an isolated type inverts the problem: the handle
/// stays outside, the graph stays inside, and only `Int`s pass between them.
///
/// Every entry point is `static` and takes only `Sendable` arguments for that
/// reason. Nothing here returns a graph value, either — a `Cogs` crossing back
/// out would reintroduce exactly the error this shape avoids.
@MainActor
enum GraphHarness {
  /// Runs one shared scenario to completion and checks it did the work its
  /// shape requires.
  ///
  /// The run-count check is not decoration. A benchmark measures however much
  /// work it is given, so a graph that silently started recomputing twice per
  /// turn would show up here as a slower number rather than as a defect —
  /// which is the failure the whole counted suite exists to prevent. Failing
  /// loudly instead keeps the timing honest.
  ///
  /// - Parameter scenario: The shared scenario to drive, from `_CogScenarios`.
  static func run(_ scenario: CogScenario) {
    let result = scenario.run(in: Cogs.forTesting())
    precondition(
      result.isExact,
      """
      \(result.name) did \(result.actualRuns) selector runs where its shape \
      requires \(result.expectedRuns). Timing a graph that is doing the wrong \
      amount of work measures the wrong thing.
      """
    )
    blackHole(result.finalValue)
  }
}

let benchmarks: @Sendable () -> Void = {
  // Allocation shapes first, on purpose — see the ordering note below.
  // Upstream discovers exactly one `benchmarks` closure per target, so every
  // file registers through here.
  allocationBenchmarks()
  propagationBenchmarks()
  edgeLayoutBenchmarks()
  memoryBenchmarks()
  boundaryBenchmarks()
  pinnedKeyBenchmarks()
  valueReferenceBenchmarks()
  // The Storefront macrobenchmark's quiescent cuts belong with the other
  // counting benchmarks, ahead of anything that drops a `Cogs`.
  storefrontCountingBenchmarks()
  runtimeComparisonBenchmarks()
  storefrontTimingBenchmarks()

  // Timing over the shared Kairo diamond, and **no counting metrics at all**.
  //
  // `M5-11` traced an intermittent SIGSEGV to this benchmark. The crash report
  // is unambiguous: a call through a null `swift_release_hook`, from
  // `completeTaskWithClosure` — the concurrency runtime finishing a task while
  // the harness tears its ARC hooks down between iterations.
  //
  // ```text
  // EXC_BAD_ACCESS (SIGSEGV) KERN_INVALID_ADDRESS at 0x0
  //   0x0
  //   _swift_release_hook
  //   _swift_release_adapter
  //   …
  //   completeTaskWithClosure
  // ```
  //
  // The tasks are Cog's own, and they are not a leak. This scenario builds and
  // drops a whole `Cogs` per iteration, and each `peek` renews a
  // `whileObserved` grace sleeper; dropping the context cancels them, and their
  // cancellation completes on another thread shortly afterwards. So a
  // whole-scenario benchmark is *by construction* not the "single-threaded
  // benchmark with quiescent background allocation" upstream says its
  // process-global counters require.
  //
  // Hence the bound rather than a workaround: counting metrics belong on
  // benchmarks whose measured region is quiescent, and this one's is not.
  // Measured 0 failures in 20 runs without them, against 2 in 12 with them.
  //
  // The same non-quiescence is why this registers **after** the allocation
  // benchmarks. Counting is process-global, so a context torn down here would
  // otherwise land its cancelled sleepers inside a later benchmark's measured
  // region — which is the likeliest explanation for the stray malloc deviation
  // `M5-08a` saw against `perf-06-value-reference`'s zero ceiling.
  Benchmark(
    "kairo-diamond",
    configuration: .init(
      metrics: [.wallClock, .instructions, .peakMemoryResident],
      warmupIterations: 2,
      maxDuration: .seconds(3),
      // Reported, never gated. M5 gates allocations, which are exact; timing
      // gates are M6's (`M6-11d`, generous absolute thresholds), and upstream's
      // default 5% relative threshold would fail on ordinary jitter.
      thresholds: [
        .wallClock: .init(),
        .instructions: .init(),
        .peakMemoryResident: .init(),
      ]
    )
  ) { _ in
    await GraphHarness.run(.kairoDiamond(width: 5, turns: 100))
  }
}
