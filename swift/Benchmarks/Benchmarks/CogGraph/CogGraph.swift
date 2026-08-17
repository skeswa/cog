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
  Benchmark.defaultConfiguration = .init(
    // Everything `M5-05ba` verified and `M5-05bb` proved live on this host.
    // No thresholds yet: `M5-06` and `M5-07a`–`M5-07d` add them one measured
    // result at a time, because a threshold without a measurement behind it is
    // a guess that fails at the worst moment.
    metrics: [
      .wallClock,
      .mallocCountTotal,
      .freeCountTotal,
      .peakMemoryResident,
      .objectAllocCount,
      .retainCount,
      .releaseCount,
      .instructions,
    ],
    warmupIterations: 2,
    maxDuration: .seconds(3)
  )

  // One benchmark, over the shared Kairo diamond. `M5-06` onward add the
  // shapes that carry thresholds; this one exists to prove the whole path —
  // pinned harness, isolation shim, shared scenarios, release build — works
  // end to end.
  Benchmark("kairo-diamond") { _ in
    await GraphHarness.run(.kairoDiamond(width: 5, turns: 100))
  }
}
