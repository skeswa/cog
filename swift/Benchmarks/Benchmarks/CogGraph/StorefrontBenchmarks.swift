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

  /// Fixture-derived verifier storage prepared outside every measured region.
  static let preparedWorld = StorefrontWorld(profile: profile)

  /// The catalog the compute-only control scores, built once.
  ///
  /// Fixture construction is not part of what the control measures — it is the
  /// *input* — so it happens here rather than inside the measured region.
  static let controlCatalog = preparedWorld.catalog

  // MARK: - Cold start

  /// Builds a runtime and materializes the first complete screen.
  ///
  /// Everything is inside the measured region on purpose: bootstrap, graph
  /// construction, the two root responses, the search index, and the first
  /// viewport's inventory and offers. This is the only cut that measures what a
  /// graph costs to *create*, which every other benchmark in this package
  /// deliberately warms away.
  static func runColdStart(preparedWorld: StorefrontWorld) async throws
    -> StorefrontSessionDriver
  {
    let driver = StorefrontSessionDriver(
      profile: profile,
      holds: .all,
      preparedWorld: preparedWorld,
      recordsCheckpoints: false
    )
    try await driver.runColdStart()
    blackHole(driver.sink.visibleChecksum)
    return driver
  }

  // MARK: - Whole session

  /// Runs the complete standard interaction trace.
  static func runSession(preparedWorld: StorefrontWorld) async throws -> StorefrontSessionDriver {
    let driver = StorefrontSessionDriver(
      profile: profile,
      holds: .all,
      preparedWorld: preparedWorld,
      recordsCheckpoints: false
    )
    try await driver.runStandardTrace()
    blackHole(driver.sink.visibleChecksum)
    return driver
  }

  /// Validates one measured driver only after its timer has stopped.
  ///
  /// The phase-by-phase verifier is the Storefront package's correctness gate.
  /// A reported sample instead proves its final independent shadow digest and
  /// exact request quiescence here, keeping verifier kernels out of the timing.
  static func validateMeasuredDriver(
    _ driver: StorefrontSessionDriver,
    against world: StorefrontWorld? = nil
  ) async {
    await driver.requireSettledOutput(against: world)
  }

  // MARK: - Quiescent interactions

  /// The settled runtime the interaction cut drives, held across every sample.
  static var interactionDriver: StorefrontSessionDriver?

  /// Products the interaction loop touches, all of them on screen.
  static var interactionProducts: [ProductID] = []

  /// Shadow state replayed only after each measured interaction batch.
  static var interactionWorld: StorefrontWorld?

  /// Monotonic interaction ordinal across warmups and reported samples.
  static var interactionIteration = 0

  /// A measured range whose operations can be replayed after timing.
  struct InteractionBatch: Sendable {
    /// First global interaction ordinal in the batch.
    let range: Range<Int>
  }

  /// Builds and settles the interaction runtime exactly once.
  ///
  /// Once, not once per iteration, and that is what makes the measured region
  /// quiescent enough to carry process-global allocation and ARC counters
  /// (`M5-11`). The context is never dropped, the mechanism's reactions hold
  /// durable leases so no `whileObserved` grace sleeper is scheduled, and the
  /// scripted service is left with nothing outstanding.
  static func settleInteractions() async throws {
    guard interactionDriver == nil else { return }
    let driver = StorefrontSessionDriver(
      profile: profile,
      holds: .quiescentBrowse,
      preparedWorld: preparedWorld
    )
    try await driver.runColdStart()
    driver.requireCheckpointsHold()
    guard !driver.sink.visibleProductIDs.isEmpty else {
      fatalError("The Storefront interaction cut settled with nothing on screen.")
    }
    interactionProducts = driver.sink.visibleProductIDs
    interactionWorld = driver.world
    interactionDriver = driver
    // Materialize every keyed source and stabilize the cart and favorite
    // collections before process-global counters are armed. The next lap still
    // changes all four values; this only makes "steady" mean already built.
    let primingBatch = runInteractions(interactionProducts.count)
    await validateInteractions(primingBatch)
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
  static func runInteractions(_ count: Int) -> InteractionBatch {
    guard let driver = interactionDriver else {
      fatalError("The Storefront interaction cut was driven before it was settled.")
    }
    let cogs = driver.cogs
    let products = interactionProducts
    let start = interactionIteration
    let end = start + count
    for iteration in start..<end {
      guard
        let interaction = StorefrontSession.steadyInteraction(
          at: iteration,
          products: products,
          variantCount: profile.variantCount
        )
      else {
        fatalError("The Storefront interaction cut has no settled products.")
      }
      cogs.toggleFavorite(interaction.productID)
      cogs.setCartQuantity(interaction.quantity, for: interaction.productID)
      cogs.selectVariant(interaction.variantIndex, for: interaction.productID)
      cogs.openProduct(interaction.productID, rank: interaction.viewRank)
    }
    interactionIteration = end
    blackHole(driver.sink.visibleChecksum)
    return InteractionBatch(range: start..<end)
  }

  /// Replays a measured batch into the plain shadow and validates its output.
  ///
  /// Replay is outside the measured region. Quantities alternate between one
  /// and two on successive laps, variants advance on every lap, favorites
  /// always toggle, and ranks are globally monotonic; no persistent sample can
  /// degrade into repeatedly writing the values it already holds.
  static func validateInteractions(_ batch: InteractionBatch) async {
    guard let driver = interactionDriver, var world = interactionWorld else {
      fatalError("The Storefront interaction batch was validated before it was settled.")
    }
    let products = interactionProducts
    for iteration in batch.range {
      guard
        let interaction = StorefrontSession.steadyInteraction(
          at: iteration,
          products: products,
          variantCount: profile.variantCount
        )
      else {
        fatalError("The Storefront interaction replay has no settled products.")
      }
      let id = interaction.productID
      if world.favorites.contains(id) {
        world.favorites.remove(id)
      } else {
        world.favorites.insert(id)
      }
      world.cartQuantities[id] = interaction.quantity
      if !world.cartContents.contains(id) { world.cartContents.append(id) }
      world.variants[id] = interaction.variantIndex
      world.viewRanks[id] = interaction.viewRank
    }
    interactionWorld = world
    await validateMeasuredDriver(driver, against: world)
  }

  // MARK: - Footprint

  /// Contexts the footprint cut has already measured, retained forever.
  ///
  /// Retained, not released, and that is the whole reason this cut can carry
  /// allocation counters at all. Releasing a `Cogs` between iterations would
  /// drop thousands of states and cancel their grace sleepers, and the frees
  /// would land inside the *next* iteration's measured region — the exact
  /// process-global attribution error `M5-11` recorded, with the null
  /// `swift_release_hook` crash on the other side of it. Nothing is ever torn
  /// down here, so nothing can be misattributed.
  ///
  /// The cost is real and bounded: `maxIterations` is small precisely because
  /// each retained context is a whole standard-profile graph.
  static var footprintContexts: [StorefrontSessionDriver] = []

  /// The context built for the next measured materialization.
  static var pendingFootprintContext: StorefrontSessionDriver?

  /// Builds a context and settles its async roots, materializing no keyed state.
  ///
  /// This runs *outside* the measured region, and the split is the design. The
  /// catalog, the account, and the search index are async: their tasks start,
  /// suspend on the scripted service, and complete on another thread. A region
  /// that contained any of that could not carry a malloc counter. So the roots
  /// are resolved first and the measured region contains only synchronous
  /// graph construction.
  ///
  /// The read that demands the roots is deliberately the *candidate list* — the
  /// last node upstream of the keyed funnel. It pulls the catalog and the search
  /// index and produces a list of ordinals, and it creates not one per-product
  /// state, which is what leaves the whole funnel for the measured region.
  static func prepareFootprint() async throws {
    let driver = StorefrontSessionDriver(
      profile: profile,
      holds: [.account],
      preparedWorld: preparedWorld
    )

    // Demand the roots. Tracked, never `peek`: a one-shot peek renews a
    // `whileObserved` grace sleeper, which is a task and an allocation, and
    // this cut exists to count allocations.
    blackHole(driver.cogs[storefrontSearchCandidateIDsCog].count)

    await driver.awaitStarted([.catalog, .account, .searchIndex])
    // The account first, so no later state is built against a signed-out
    // shopper and rebuilt after sign-in. Then the index generation that was
    // started over the empty catalog, then the catalog itself, then the index
    // generation the real catalog invalidates into.
    try await driver.release(.account)
    try await driver.release(.searchIndex)
    try await driver.release(.catalog)
    await driver.awaitStarted([.searchIndex, .searchIndex])
    try await driver.release(.searchIndex)
    try await driver.drainRequests()

    pendingFootprintContext = driver
  }

  /// Materializes the catalog-wide keyed funnel, and nothing else.
  ///
  /// One tracked read of the ranked list demands, synchronously:
  ///
  /// - one `storefrontFilterEligibilityCogs` state per catalog product;
  /// - one `storefrontSearchScoreCogs` state per eligible product; and
  /// - the two keyless nodes that gather them.
  ///
  /// With no query, no category, and no stock filter, every product is
  /// eligible, so the count is exactly `2 × productCount + 2` states — and the
  /// returned rank count proves it, because a product can only appear in the
  /// ranked list if both of its keyed states were created and read.
  ///
  /// No async is demanded anywhere on that path, which is what keeps the region
  /// quiescent.
  ///
  /// - Returns: How many products the funnel ranked.
  static func materializeFootprint() -> Int {
    guard let driver = pendingFootprintContext else {
      fatalError("The Storefront footprint cut was measured before it was prepared.")
    }
    let rankedProducts = driver.cogs[storefrontRankedProductIDsCog]
    return rankedProducts.count
  }

  /// Checks the materialization and retains the context so nothing is released.
  ///
  /// - Parameter rankedCount: What ``materializeFootprint()`` returned.
  static func retainFootprint(rankedCount: Int) {
    guard rankedCount == profile.productCount else {
      fatalError(
        """
        The Storefront footprint cut ranked \(rankedCount) products where the profile has \
        \(profile.productCount). The state count this cut reports allocations for is derived \
        from that number, so a timing taken here would be a cost with no denominator.
        """
      )
    }
    guard let driver = pendingFootprintContext else {
      fatalError("The Storefront footprint cut retained a context it never prepared.")
    }
    footprintContexts.append(driver)
    pendingFootprintContext = nil
  }

  /// The keyed and keyless states one footprint iteration creates.
  ///
  /// Derived from the profile, never observed: an eligibility state and a score
  /// state per product, plus the eligible list and the ranked list. Reported as
  /// a custom metric so a reader can divide the allocation columns by it
  /// without doing arithmetic from a paragraph.
  static var footprintStateCount: Int { profile.productCount * 2 + 2 }

  // MARK: - Async burst

  /// The settled runtime the burst cut drives, held across every sample.
  static var burstDriver: StorefrontSessionDriver?

  /// Which generation the next burst publishes.
  static var burstGeneration = 0

  /// Shadow state advanced only after each measured burst.
  static var burstWorld: StorefrontWorld?

  /// Inputs selected before one burst timer starts.
  struct BurstInput: Sendable {
    /// Rows the held browse reaction currently demands.
    let touched: [ProductID]

    /// Inventory generation published by this burst.
    let generation: Int
  }

  /// Builds and settles the burst runtime exactly once.
  static func settleBurst() async throws {
    guard burstDriver == nil else { return }
    let driver = StorefrontSessionDriver(
      profile: profile,
      holds: .quiescentBrowse,
      preparedWorld: preparedWorld
    )
    try await driver.runColdStart()
    driver.requireCheckpointsHold()
    burstWorld = driver.world
    burstDriver = driver
  }

  /// Snapshots one burst's inputs outside the measured region.
  static func prepareBurst() -> BurstInput {
    guard let driver = burstDriver else {
      fatalError("The Storefront burst cut was prepared before it was settled.")
    }
    burstGeneration += 1
    return BurstInput(touched: driver.sink.demandedProductIDs, generation: burstGeneration)
  }

  /// Publishes one inventory burst, accepts every response, and settles.
  ///
  /// The measured region covers the whole round trip a warehouse feed causes:
  /// one multi-key turn, the requests the demanded rows start, the
  /// acceptance of each response, the graph settlement each acceptance causes,
  /// and the observation work that re-renders the affected rows.
  static func runBurst(_ input: BurstInput) async throws {
    guard let driver = burstDriver else {
      fatalError("The Storefront burst cut was driven before it was settled.")
    }
    try await driver.runInventoryBurst(touching: input.touched, generation: input.generation)
    blackHole(driver.sink.visibleChecksum)
  }

  /// Validates a measured inventory burst after its timer has stopped.
  static func validateBurst(_ input: BurstInput) async {
    guard let driver = burstDriver, var world = burstWorld else {
      fatalError("The Storefront burst cut was validated before it was settled.")
    }
    guard !input.touched.isEmpty else {
      fatalError("The Storefront burst cut touched no rows.")
    }
    guard input.touched == driver.sink.demandedProductIDs else {
      fatalError(
        "The Storefront burst touched \(input.touched.count) rows but the browse reaction demanded \(driver.sink.demandedProductIDs.count)."
      )
    }
    for id in input.touched { world.inventoryGenerations[id] = input.generation }
    burstWorld = world
    await validateMeasuredDriver(driver, against: world)
  }

  // MARK: - Compute-only control

  /// Runs every heavy kernel over the same inputs with no graph at all.
  ///
  /// Reported *beside* the application cuts and never subtracted from them.
  /// Differencing two noisy measurements produces a third, noisier number that
  /// looks authoritative and is not; printing both and letting a reader see the
  /// ratio is honest and just as useful.
  static func runComputeControl(
    catalog: CatalogSnapshot
  ) -> StorefrontKernels.ComputeControlResult {
    let result = StorefrontKernels.computeControl(for: profile, catalog: catalog)
    blackHole(result.checksum)
    return result
  }

  /// Validates the compute-only result after its timer has stopped.
  static func validateComputeControl(_ result: StorefrontKernels.ComputeControlResult) {
    guard result.indexedTokens > 0, result.candidateCount > 0 else {
      fatalError("The Storefront compute control produced an empty index or no candidates.")
    }
  }
}

/// The Storefront cuts whose measured region is quiescent.
///
/// Registered with the other counting benchmarks and **before** any benchmark
/// that drops a `Cogs` or leaves work on another thread, because counting is
/// process-global: teardown from a non-quiescent benchmark lands in whichever
/// benchmark measures next (`M5-11`).
let storefrontCountingBenchmarks: @Sendable () -> Void = {
  // Allocation *counts* and allocation *bytes*, both net and gross.
  //
  // `peakMemoryResidentDelta` is what the non-quiescent cuts have to settle
  // for, and it is a poor instrument: resident memory is OS-sampled,
  // page-granular, and a high-water mark that never comes down, so it answers
  // "did this process ever get big" rather than "what does this graph cost".
  // The interposer's counters answer the real question exactly:
  //
  // - `mallocCountTotal` / `freeCountTotal` — allocations made and returned;
  // - `mallocFreeDelta` — allocations that **survived** the region, which for a
  //   build region is the graph's allocation footprint and for a steady-state
  //   region should be zero;
  // - `mallocBytesCount` — gross bytes requested;
  // - `memoryLeakedBytes` — bytes that survived the region, which is the
  //   closest thing to "heap held" that can be counted rather than sampled.
  let countingMetrics: [BenchmarkMetric] = [
    .mallocCountTotal, .freeCountTotal, .mallocFreeDelta, .mallocBytesCount,
    .memoryLeakedBytes, .objectAllocCount, .retainCount, .releaseCount, .wallClock,
    .instructions,
  ]
  // Reported, never gated. This workload has no pinned-CI history yet, and a
  // threshold with no repeated measurement behind it is a guess that fails at
  // the worst moment. `impl/benchmarks.md` records the first measurements and names
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
    let batch = await StorefrontHarness.runInteractions(count)
    benchmark.stopMeasurement()
    await StorefrontHarness.validateInteractions(batch)
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
    let catalog = await StorefrontHarness.controlCatalog
    benchmark.startMeasurement()
    let result = await StorefrontHarness.runComputeControl(catalog: catalog)
    benchmark.stopMeasurement()
    await StorefrontHarness.validateComputeControl(result)
  }

  // What a catalog-wide keyed funnel costs to *build and hold*.
  //
  // Three iterations and no warm-up, because every iteration retains a whole
  // standard-profile context forever — see `StorefrontHarness.footprintContexts`
  // for why releasing one would make the next iteration's counters a fiction.
  // Three is enough: these are exact interposer counts rather than a sampled
  // distribution, so agreement from p0 to p100 is the result, and disagreement
  // would itself be the finding.
  Benchmark(
    "perf-15-storefront-footprint",
    configuration: .init(
      metrics: countingMetrics + [footprintStateMetric],
      warmupIterations: 0,
      maxDuration: .seconds(120),
      maxIterations: 3,
      thresholds: reportedOnly.merging([footprintStateMetric: BenchmarkThresholds()]) {
        current, _ in current
      }
    )
  ) { benchmark in
    try await StorefrontHarness.prepareFootprint()
    benchmark.startMeasurement()
    let rankedCount = await StorefrontHarness.materializeFootprint()
    benchmark.stopMeasurement()
    await StorefrontHarness.retainFootprint(rankedCount: rankedCount)
    benchmark.measurement(footprintStateMetric, await StorefrontHarness.footprintStateCount)
  }
}

/// States one footprint iteration materializes.
///
/// A custom metric because it is a *count of graph states*, which no built-in
/// metric expresses, and because carrying it beside the allocation columns is
/// what lets a reader divide one by the other. Unscaled: the count is the
/// count, not a count per thousand iterations.
private let footprintStateMetric = BenchmarkMetric.custom(
  "storefrontStates",
  polarity: .prefersSmaller,
  useScalingFactor: false
)

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
  // Every cut below pins `maxIterations`, and the reason is the memory columns
  // rather than the timing ones. `peakMemoryResident` is a process-wide
  // high-water mark that never comes down, and `peakMemoryResidentDelta` only
  // advances on iterations where that mark moves. Left to a duration budget, a
  // core that is ten times faster runs ten times as many build-and-drop cycles
  // in the same window and gives the allocator ten times as many chances to
  // reach higher — so the two columns would compare throughput while looking
  // like they compare footprint. A fixed iteration count makes them comparable.
  // The exact footprint question is answered by
  // `perf-15-storefront-footprint`'s counted bytes, not by these.
  let reported = BenchmarkThresholds()
  let reportedOnly = Dictionary(uniqueKeysWithValues: timingMetrics.map { ($0, reported) })

  Benchmark(
    "perf-15-storefront-cold",
    configuration: .init(
      metrics: timingMetrics,
      warmupIterations: 1,
      maxDuration: .seconds(120),
      maxIterations: 10,
      thresholds: reportedOnly
    )
  ) { benchmark in
    let preparedWorld = await StorefrontHarness.preparedWorld
    benchmark.startMeasurement()
    let driver = try await StorefrontHarness.runColdStart(preparedWorld: preparedWorld)
    benchmark.stopMeasurement()
    await StorefrontHarness.validateMeasuredDriver(driver)
  }

  Benchmark(
    "perf-15-storefront-async-burst",
    configuration: .init(
      metrics: timingMetrics,
      warmupIterations: 1,
      maxDuration: .seconds(120),
      maxIterations: 50,
      thresholds: reportedOnly
    )
  ) { benchmark in
    try await StorefrontHarness.settleBurst()
    let input = await StorefrontHarness.prepareBurst()
    benchmark.startMeasurement()
    try await StorefrontHarness.runBurst(input)
    benchmark.stopMeasurement()
    await StorefrontHarness.validateBurst(input)
  }

  Benchmark(
    "perf-15-storefront-session",
    configuration: .init(
      metrics: timingMetrics,
      warmupIterations: 1,
      maxDuration: .seconds(180),
      maxIterations: 3,
      thresholds: reportedOnly
    )
  ) { benchmark in
    let preparedWorld = await StorefrontHarness.preparedWorld
    benchmark.startMeasurement()
    let driver = try await StorefrontHarness.runSession(preparedWorld: preparedWorld)
    benchmark.stopMeasurement()
    await StorefrontHarness.validateMeasuredDriver(driver)
  }
}
