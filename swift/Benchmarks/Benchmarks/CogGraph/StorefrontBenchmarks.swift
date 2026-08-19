import Benchmark
internal import Cog
import CogStorefront

/// The Storefront macrobenchmark's five cuts, and the MainActor owner they run
/// behind.
///
/// This is the one workload in the suite that is an *application* rather than a
/// graph shape. Everything else here measures a structure — a diamond, a fan, a
/// chain — chosen because it isolates one cost. This measures a commerce
/// session: a catalog, a search, a filter bar, a sixteen-stage pricing ladder,
/// a cart, quotes, and an inventory feed, driven through named domain verbs by
/// the same trace the SwiftUI benchmark application performs.
///
/// It complements the synthetic benchmarks rather than replacing them. A
/// regression here says *something* got slower; the synthetic ones say what.
///
/// Isolated for the reason `M5-05bb` recorded — see ``GraphHarness``.
@MainActor
enum StorefrontHarness {
  /// The profile every reported cut runs.
  ///
  /// `standard`, always. The smoke profile is for correctness and the stress
  /// profile is for local exploration; a reported number that could have come
  /// from either would mean nothing.
  static let profile = StorefrontProfile.standard

  /// The catalog the compute-only control scores, built once.
  ///
  /// Fixture construction is not part of what the control measures — it is the
  /// *input* — so it happens here rather than inside the measured region.
  static let controlCatalog = StorefrontFixtures.catalog(for: profile)

  // MARK: - Cold start

  /// Builds a runtime and materializes the first complete screen.
  ///
  /// Everything is inside the measured region on purpose: bootstrap, graph
  /// construction, the two root responses, the search index, and the first
  /// viewport's inventory and offers. This is the only cut that measures what a
  /// graph costs to *create*, which every other benchmark in this package
  /// deliberately warms away.
  static func runColdStart() async throws {
    let driver = StorefrontSessionDriver(profile: profile, holds: .all)
    try await driver.runColdStart()
    driver.requireCheckpointsHold()
    blackHole(driver.sink.visibleChecksum)
  }

  // MARK: - Whole session

  /// Runs the complete standard interaction trace.
  static func runSession() async throws {
    let driver = StorefrontSessionDriver(profile: profile, holds: .all)
    try await driver.runStandardTrace()
    driver.requireCheckpointsHold()
    blackHole(driver.sink.visibleChecksum)
  }

  // MARK: - Quiescent interactions

  /// The settled runtime the interaction cut drives, held across every sample.
  static var interactionDriver: StorefrontSessionDriver?

  /// Products the interaction loop touches, all of them on screen.
  static var interactionProducts: [ProductID] = []

  /// Monotonic rank the multi-source verb hands out.
  static var interactionRank = 0

  /// Builds and settles the interaction runtime exactly once.
  ///
  /// Once, not once per iteration, and that is what makes the measured region
  /// quiescent enough to carry process-global allocation and ARC counters
  /// (`M5-11`). The context is never dropped, the mechanism's reactions hold
  /// durable leases so no `whileObserved` grace sleeper is scheduled, and the
  /// scripted service is left with nothing outstanding.
  static func settleInteractions() async throws {
    guard interactionDriver == nil else { return }
    let driver = StorefrontSessionDriver(profile: profile, holds: .quiescentBrowse)
    try await driver.runColdStart()
    driver.requireCheckpointsHold()
    precondition(
      !driver.sink.visibleProductIDs.isEmpty,
      "The Storefront interaction cut settled with nothing on screen."
    )
    interactionProducts = driver.sink.visibleProductIDs
    interactionDriver = driver
  }

  /// Drives `count` synchronous interactions against the settled runtime.
  ///
  /// Four verbs per iteration, and every one of them is a write a shopper
  /// actually performs: a favorite toggle, a cart quantity, a variant
  /// selection, and the two-source verb that opens a product and records that
  /// it was viewed. None of them changes *which* rows are on screen, and that
  /// restriction is deliberate rather than incidental — a query change would
  /// materialize new rows, which would start inventory and offer requests, and
  /// a measured region that starts async work is not a region process-global
  /// counters may be attached to. Search interactions are measured by the
  /// session cut instead, on wall clock alone.
  ///
  /// - Parameter count: How many iterations to drive.
  static func runInteractions(_ count: Int) {
    guard let driver = interactionDriver else {
      fatalError("The Storefront interaction cut was driven before it was settled.")
    }
    let cogs = driver.cogs
    let products = interactionProducts
    for index in 0..<count {
      let id = products[index % products.count]
      cogs.toggleFavorite(id)
      cogs.setCartQuantity(index % 3, for: id)
      cogs.selectVariant(index % max(1, profile.variantCount), for: id)
      interactionRank += 1
      cogs.openProduct(id, rank: interactionRank)
    }
    blackHole(driver.sink.visibleChecksum)
  }

  // MARK: - Async burst

  /// The settled runtime the burst cut drives, held across every sample.
  static var burstDriver: StorefrontSessionDriver?

  /// Which generation the next burst publishes.
  static var burstGeneration = 0

  /// Builds and settles the burst runtime exactly once.
  static func settleBurst() async throws {
    guard burstDriver == nil else { return }
    let driver = StorefrontSessionDriver(profile: profile, holds: .quiescentBrowse)
    try await driver.runColdStart()
    driver.requireCheckpointsHold()
    burstDriver = driver
  }

  /// Publishes one inventory burst, accepts every response, and settles.
  ///
  /// The measured region covers the whole round trip a warehouse feed causes:
  /// one multi-key commit, the requests the demanded rows start, the
  /// acceptance of each response, the graph settlement each acceptance causes,
  /// and the observation work that re-renders the affected rows.
  static func runBurst() async throws {
    guard let driver = burstDriver else {
      fatalError("The Storefront burst cut was driven before it was settled.")
    }
    burstGeneration += 1
    let touched = try await driver.runDemandedInventoryBurst(generation: burstGeneration)
    precondition(!touched.isEmpty, "The Storefront burst cut touched no rows.")
    blackHole(driver.sink.visibleChecksum)
  }

  // MARK: - Compute-only control

  /// Runs every heavy kernel over the same inputs with no graph at all.
  ///
  /// Reported *beside* the application cuts and never subtracted from them.
  /// Differencing two noisy measurements produces a third, noisier number that
  /// looks authoritative and is not; printing both and letting a reader see the
  /// ratio is honest and just as useful.
  static func runComputeControl() {
    let result = StorefrontKernels.computeControl(for: profile, catalog: controlCatalog)
    precondition(
      result.indexedTokens > 0 && result.candidateCount > 0,
      "The Storefront compute control produced an empty index or no candidates."
    )
    blackHole(result.checksum)
  }
}

/// The Storefront cuts whose measured region is quiescent.
///
/// Registered with the other counting benchmarks and **before** any benchmark
/// that drops a `Cogs` or leaves work on another thread, because counting is
/// process-global: teardown from a non-quiescent benchmark lands in whichever
/// benchmark measures next (`M5-11`).
let storefrontCountingBenchmarks: @Sendable () -> Void = {
  let countingMetrics: [BenchmarkMetric] = [
    .mallocCountTotal, .objectAllocCount, .retainCount, .releaseCount, .wallClock,
    .instructions,
  ]
  // Reported, never gated. This workload has no pinned-CI history yet, and a
  // threshold with no repeated measurement behind it is a guess that fails at
  // the worst moment. `perf.md` §9.6 records the first measurements and names
  // what promotion would require.
  let reported = BenchmarkThresholds()
  let reportedOnly = Dictionary(
    uniqueKeysWithValues: countingMetrics.map { ($0, reported) }
  )

  Benchmark(
    "perf-15-storefront-interactions",
    configuration: .init(
      metrics: countingMetrics,
      warmupIterations: 2,
      maxDuration: .seconds(3),
      thresholds: reportedOnly
    )
  ) { benchmark in
    try await StorefrontHarness.settleInteractions()
    let count = benchmark.scaledIterations.count
    benchmark.startMeasurement()
    await StorefrontHarness.runInteractions(count)
    benchmark.stopMeasurement()
  }

  Benchmark(
    "perf-15-storefront-compute-control",
    configuration: .init(
      metrics: countingMetrics,
      warmupIterations: 2,
      maxDuration: .seconds(3),
      thresholds: reportedOnly
    )
  ) { benchmark in
    benchmark.startMeasurement()
    await StorefrontHarness.runComputeControl()
    benchmark.stopMeasurement()
  }
}

/// The Storefront cuts whose measured region is not quiescent.
///
/// Wall clock, instructions, and resident memory only. Each of these builds or
/// drives a runtime that starts tasks, accepts async completions, or is dropped
/// at the end of a sample, and `M5-11`'s rule is explicit that such a region
/// must stay off the ARC and malloc counters — the harness tears its ARC hooks
/// down between iterations, and a task finishing on another thread then calls
/// through a null `swift_release_hook`.
let storefrontTimingBenchmarks: @Sendable () -> Void = {
  let timingMetrics: [BenchmarkMetric] = [
    .wallClock, .cpuTotal, .instructions, .peakMemoryResidentDelta, .peakMemoryResident,
  ]
  let reported = BenchmarkThresholds()
  let reportedOnly = Dictionary(uniqueKeysWithValues: timingMetrics.map { ($0, reported) })

  Benchmark(
    "perf-15-storefront-cold",
    configuration: .init(
      metrics: timingMetrics,
      warmupIterations: 1,
      maxDuration: .seconds(5),
      thresholds: reportedOnly
    )
  ) { benchmark in
    benchmark.startMeasurement()
    try await StorefrontHarness.runColdStart()
    benchmark.stopMeasurement()
  }

  Benchmark(
    "perf-15-storefront-async-burst",
    configuration: .init(
      metrics: timingMetrics,
      warmupIterations: 1,
      maxDuration: .seconds(5),
      thresholds: reportedOnly
    )
  ) { benchmark in
    try await StorefrontHarness.settleBurst()
    benchmark.startMeasurement()
    try await StorefrontHarness.runBurst()
    benchmark.stopMeasurement()
  }

  Benchmark(
    "perf-15-storefront-session",
    configuration: .init(
      metrics: timingMetrics,
      warmupIterations: 1,
      maxDuration: .seconds(10),
      thresholds: reportedOnly
    )
  ) { benchmark in
    benchmark.startMeasurement()
    try await StorefrontHarness.runSession()
    benchmark.stopMeasurement()
  }
}
