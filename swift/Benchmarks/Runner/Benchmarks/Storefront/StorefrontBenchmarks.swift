import Benchmark
internal import Cog
import CogStorefront
import StorefrontWorkload

/// The inputs every Storefront cut shares, whichever runtime performs them.
///
/// Static and non-generic on purpose. The profile decides the catalog, the
/// pricing ladder, and every expectation derived from them, so four runtimes
/// that built their own would be four different sessions rather than one
/// session performed four ways. One profile and one prepared world, built once
/// and handed to every harness, is what makes the comparison a comparison.
@MainActor
enum StorefrontWorkloadInputs {
  /// The profile every reported cut runs.
  ///
  /// `standard`, always. The smoke profile is for correctness and the stress
  /// profile is for local exploration; a reported number that could have come
  /// from either would mean nothing.
  static let profile = StorefrontProfile.standard

  /// Fixture-derived verifier storage prepared outside every measured region.
  ///
  /// A value type, so each driver receives a copy and mutates only its own.
  /// Sharing the *construction* across runtimes is the point; sharing the
  /// storage would let one runtime's session move another's shadow.
  static let preparedWorld = StorefrontWorld(profile: profile)

  /// The catalog the compute-only control scores, built once.
  ///
  /// Fixture construction produces the input, so it stays outside the measured
  /// region.
  static let controlCatalog = preparedWorld.catalog

  /// Runs every heavy kernel over the same inputs with no graph at all.
  ///
  /// Reported *beside* the application cuts and never subtracted from them.
  /// Differencing two noisy measurements produces a third, noisier number that
  /// looks authoritative and is not; printing both and letting a reader see the
  /// ratio is honest and just as useful.
  ///
  /// Deliberately not a method on ``StorefrontHarness``: it holds no graph at
  /// all, so it has no runtime to be generic over, and repeating it once per
  /// runtime would measure the same call four times under four names.
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

/// A measured range of steady interactions whose operations can be replayed
/// after timing.
///
/// Top-level and non-generic so it can carry a measured batch back out to a
/// nonisolated `Benchmark` body whichever runtime produced it. It holds
/// ordinals, never runtime state.
struct StorefrontInteractionBatch: Sendable {
  /// First global interaction ordinal in the batch.
  let range: Range<Int>
}

/// The inputs one inventory burst is measured over.
///
/// Top-level and non-generic for the same reason as
/// ``StorefrontInteractionBatch``: it crosses back out to the benchmark body,
/// and everything in it is plain data.
struct StorefrontBurstInput: Sendable {
  /// Rows the held browse observer currently demands.
  let touched: [ProductID]

  /// Inventory generation published by this burst.
  let generation: Int
}

/// Storefront benchmark cuts and their generic MainActor runtime owner.
///
/// This workload measures an *application*, not a graph shape. Other benchmarks
/// use diamonds, fans, and chains to isolate one cost. This measures a commerce
/// session: a catalog, a search, a filter bar, a sixteen-stage pricing ladder,
/// a cart, quotes, and an inventory feed, driven through named domain verbs by
/// the same trace the SwiftUI benchmark application performs.
///
/// It complements the synthetic benchmarks rather than replacing them. A
/// regression here says *something* got slower; the synthetic ones say what.
///
/// ## Why it is generic
///
/// `perf-16` measures Cog, raw Swift Observation, hand-memoized Observation, and
/// swift-state-graph over the same eleven-phase session. Separate harnesses
/// could compare their own differences:
/// one that settled its runtime a little differently, or validated a little
/// less, would produce a number that looks like a property of the runtime and
/// is a property of the apparatus. One generic harness makes the measured code
/// path literally the same source for all four, and `perf-15`'s Cog-only cuts
/// run through this same class at `Runtime == CogStorefrontRuntime`, so their
/// agreement with `perf-16-storefront-cog-*` is a free self-check on it.
///
/// ## Identity and ownership
///
/// One instance per runtime, created once and retained for the whole process by
/// ``StorefrontComparisonHarness``. A class rather than the `enum` this used to
/// be because Swift has no static stored properties in a generic type, and the
/// settled interaction runtime, burst runtime, and footprint contexts must
/// outlive each sample. `M5-11` requires this for process-global counters.
///
/// MainActor-isolated for the reason `M5-05bb` records; see ``GraphHarness``.
@MainActor
final class StorefrontHarness<Runtime: StorefrontRuntime> {
  /// The profile every cut this harness runs uses.
  var profile: StorefrontProfile { StorefrontWorkloadInputs.profile }

  /// The fixture-derived world every driver this harness builds starts from.
  var preparedWorld: StorefrontWorld { StorefrontWorkloadInputs.preparedWorld }

  /// Creates the one harness for this runtime.
  init() {}

  // MARK: - Cold start and whole session

  /// The driver the last measured cold start or session produced.
  ///
  /// Held rather than returned because a `StorefrontSessionDriver` is not
  /// `Sendable` and a benchmark body is nonisolated: handing one back out is
  /// exactly the error the isolated-harness shape exists to avoid.
  ///
  /// ``validateMeasuredDriver()`` clears it, so the release of a measured
  /// driver still lands *after* `stopMeasurement()` rather than inside the next
  /// sample's timed region.
  private var lastMeasuredDriver: StorefrontSessionDriver<Runtime>?

  /// Builds a runtime and materializes the first complete screen.
  ///
  /// Everything is inside the measured region on purpose: assembly, graph
  /// construction, the two root responses, the search index, and the first
  /// viewport's inventory and offers. This is the only cut that measures what a
  /// graph costs to *create*, which every other benchmark in this package
  /// deliberately warms away.
  func runColdStart() async throws {
    let driver = StorefrontSessionDriver<Runtime>(
      profile: profile,
      holds: .all,
      preparedWorld: preparedWorld,
      recordsCheckpoints: false
    )
    try await driver.runColdStart()
    blackHole(driver.sink.visibleChecksum)
    lastMeasuredDriver = driver
  }

  /// Runs the complete standard interaction trace.
  func runSession() async throws {
    let driver = StorefrontSessionDriver<Runtime>(
      profile: profile,
      holds: .all,
      preparedWorld: preparedWorld,
      recordsCheckpoints: false
    )
    try await driver.runStandardTrace()
    blackHole(driver.sink.visibleChecksum)
    lastMeasuredDriver = driver
  }

  /// Validates the last measured driver only after its timer has stopped.
  ///
  /// The phase-by-phase verifier is the workload package's correctness gate. A
  /// reported sample instead proves its final independent shadow digest and
  /// exact request quiescence here, keeping verifier kernels out of the timing.
  /// It checks runtime-neutral output: visible IDs, rendered checksum,
  /// suggestions, order total, and no outstanding work. A wrong session fails
  /// instead of reporting a fast result.
  func validateMeasuredDriver() async {
    guard let driver = lastMeasuredDriver else {
      fatalError("A Storefront sample was validated without having been measured.")
    }
    lastMeasuredDriver = nil
    await driver.requireSettledOutput()
  }

  // MARK: - Quiescent interactions

  /// The settled runtime the interaction cut drives, held across every sample.
  private var interactionDriver: StorefrontSessionDriver<Runtime>?

  /// Products the interaction loop touches, all of them on screen.
  private var interactionProducts: [ProductID] = []

  /// Shadow state replayed only after each measured interaction batch.
  private var interactionWorld: StorefrontWorld?

  /// Monotonic interaction ordinal across warmups and reported samples.
  private var interactionIteration = 0

  /// Builds and settles the interaction runtime exactly once.
  ///
  /// Once, not once per iteration, and that is what makes the measured region
  /// quiescent enough to carry process-global allocation and ARC counters
  /// (`M5-11`). The context is never dropped, the held observers keep their
  /// demand so no grace sleeper is scheduled, and the scripted service is left
  /// with nothing outstanding.
  func settleInteractions() async throws {
    guard interactionDriver == nil else { return }
    let driver = StorefrontSessionDriver<Runtime>(
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
  /// it was viewed. None changes *which* rows are on screen. A query change
  /// would materialize rows and start inventory and offer requests, and
  /// a measured region that starts async work is not a region process-global
  /// counters may be attached to. Search interactions are measured by the
  /// session cut instead, on wall clock alone.
  ///
  /// - Parameter count: How many iterations to drive.
  func runInteractions(_ count: Int) -> StorefrontInteractionBatch {
    guard let driver = interactionDriver else {
      fatalError("The Storefront interaction cut was driven before it was settled.")
    }
    // Read the concrete runtime once so the specializer can devirtualize all
    // four verbs. Calling through the generic driver each time would measure
    // protocol-witness dispatch inside the loop.
    let runtime = driver.runtime
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
      runtime.toggleFavorite(interaction.productID)
      runtime.setCartQuantity(interaction.quantity, for: interaction.productID)
      runtime.selectVariant(interaction.variantIndex, for: interaction.productID)
      runtime.openProduct(interaction.productID, rank: interaction.viewRank)
    }
    interactionIteration = end
    blackHole(driver.sink.visibleChecksum)
    return StorefrontInteractionBatch(range: start..<end)
  }

  /// Replays a measured batch into the plain shadow and validates its output.
  ///
  /// Replay is outside the measured region. Quantities alternate between one
  /// and two on successive laps, variants advance on every lap, favorites
  /// always toggle, and ranks are globally monotonic; no persistent sample can
  /// degrade into repeatedly writing the values it already holds.
  func validateInteractions(_ batch: StorefrontInteractionBatch) async {
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
    await driver.requireSettledOutput(against: world)
  }

  // MARK: - Footprint

  /// Contexts the footprint cut has already measured, retained forever.
  ///
  /// Retained, not released, and that is the whole reason this cut can carry
  /// allocation counters at all. Releasing a runtime between iterations would
  /// drop thousands of states and cancel their grace sleepers. Those frees
  /// could land in the *next* measured region, causing the process-global
  /// attribution error `M5-11` records and the null
  /// `swift_release_hook` crash on the other side of it. Nothing is ever torn
  /// down here, so nothing can be misattributed.
  ///
  /// The cost is real and bounded: `maxIterations` is small precisely because
  /// each retained context is a whole standard-profile graph.
  private var footprintContexts: [StorefrontSessionDriver<Runtime>] = []

  /// The context built for the next measured materialization.
  private var pendingFootprintContext: StorefrontSessionDriver<Runtime>?

  /// Builds a context and settles its async roots, materializing no keyed state.
  ///
  /// This runs *outside* the measured region, and the split is the design. The
  /// catalog, the account, and the search index are async: their tasks start,
  /// suspend on the scripted service, and complete on another thread. A region
  /// that contained any of that could not carry a malloc counter. So the roots
  /// are resolved first and the measured region contains only synchronous
  /// graph construction.
  ///
  /// The root demand is supplied by the caller rather than performed here, and
  /// it is the one step of this cut that is *not* runtime-neutral. What has to
  /// happen is precise: start the catalog and the search index without
  /// building their funnel because measurement must build it. ``StorefrontRuntime``
  /// has no verb for this. ``StorefrontRuntime/demandRankedProductIDs()`` builds
  /// the funnel, so each concrete runtime supplies the root demand.
  ///
  /// - Parameter demandRoots: Starts the catalog and search-index requests
  ///   while creating none of the per-product funnel this cut weighs.
  func prepareFootprint(demandingRoots demandRoots: (Runtime) -> Void) async throws {
    let driver = StorefrontSessionDriver<Runtime>(
      profile: profile,
      holds: [.account],
      preparedWorld: preparedWorld
    )

    demandRoots(driver.runtime)

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
  /// With no query, category, or stock filter, every product is eligible. The
  /// count is `2 × productCount + 2` states. A product appears in the returned
  /// ranking only after both keyed states are created and read.
  ///
  /// No async is demanded anywhere on that path, which is what keeps the region
  /// quiescent.
  ///
  /// - Returns: How many products the funnel ranked.
  func materializeFootprint() -> Int {
    guard let driver = pendingFootprintContext else {
      fatalError("The Storefront footprint cut was measured before it was prepared.")
    }
    // Through the runtime verb rather than through a subscript, so every
    // runtime measures this cut with the same one call. It is a tracked read:
    // the funnel has to stay materialized to be weighed.
    let rankedProducts = driver.runtime.demandRankedProductIDs()
    return rankedProducts.count
  }

  /// Checks the materialization and retains the context so nothing is released.
  ///
  /// - Parameter rankedCount: What ``materializeFootprint()`` returned.
  func retainFootprint(rankedCount: Int) {
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
  var footprintStateCount: Int { profile.productCount * 2 + 2 }

  // MARK: - Async burst

  /// The settled runtime the burst cut drives, held across every sample.
  private var burstDriver: StorefrontSessionDriver<Runtime>?

  /// Which generation the next burst publishes.
  private var burstGeneration = 0

  /// Shadow state advanced only after each measured burst.
  private var burstWorld: StorefrontWorld?

  /// Builds and settles the burst runtime exactly once.
  func settleBurst() async throws {
    guard burstDriver == nil else { return }
    let driver = StorefrontSessionDriver<Runtime>(
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
  func prepareBurst() -> StorefrontBurstInput {
    guard let driver = burstDriver else {
      fatalError("The Storefront burst cut was prepared before it was settled.")
    }
    burstGeneration += 1
    return StorefrontBurstInput(
      touched: driver.sink.demandedProductIDs,
      generation: burstGeneration
    )
  }

  /// Publishes one inventory burst, accepts every response, and settles.
  ///
  /// The measured region covers the whole round trip a warehouse feed causes:
  /// one multi-key turn, the requests the demanded rows start, the
  /// acceptance of each response, the graph settlement each acceptance causes,
  /// and the observation work that re-renders the affected rows.
  func runBurst(_ input: StorefrontBurstInput) async throws {
    guard let driver = burstDriver else {
      fatalError("The Storefront burst cut was driven before it was settled.")
    }
    try await driver.runInventoryBurst(touching: input.touched, generation: input.generation)
    blackHole(driver.sink.visibleChecksum)
  }

  /// Validates a measured inventory burst after its timer has stopped.
  func validateBurst(_ input: StorefrontBurstInput) async {
    guard let driver = burstDriver, var world = burstWorld else {
      fatalError("The Storefront burst cut was validated before it was settled.")
    }
    guard !input.touched.isEmpty else {
      fatalError("The Storefront burst cut touched no rows.")
    }
    guard input.touched == driver.sink.demandedProductIDs else {
      fatalError(
        "The Storefront burst touched \(input.touched.count) rows but the browse observer demanded \(driver.sink.demandedProductIDs.count)."
      )
    }
    for id in input.touched { world.inventoryGenerations[id] = input.generation }
    burstWorld = world
    await driver.requireSettledOutput(against: world)
  }

  nonisolated deinit {}
}

/// The Storefront cuts whose measured region is quiescent.
///
/// Registered with the other counting benchmarks and **before** any benchmark
/// that drops a runtime or leaves work on another thread, because counting is
/// process-global: teardown from a non-quiescent benchmark lands in whichever
/// benchmark measures next (`M5-11`).
let storefrontCountingBenchmarks: @Sendable () -> Void = {
  // Allocation *counts* and allocation *bytes*, both net and gross.
  //
  // Non-quiescent cuts use `peakMemoryResidentDelta`. It is OS-sampled,
  // page-sized, and based on a high-water mark. It measures process growth, not
  // the graph's exact cost. The interposer provides exact counts:
  //
  // - `mallocCountTotal` / `freeCountTotal`: allocations made and returned.
  // - `mallocFreeDelta`: allocations that **survived** the region, which for a
  //   build region is the graph's allocation footprint and for a steady-state
  //   region should be zero.
  // - `mallocBytesCount`: gross bytes requested.
  // - `memoryLeakedBytes`: bytes that survived the region, which is the
  //   nearest counted measure of retained heap bytes.
  let countingMetrics = storefrontCountingMetrics
  // Reported, never gated. This workload has no pinned-CI history yet, and a
  // threshold with no repeated measurement behind it is a guess that fails at
  // the worst moment. `impl/perf.md` records the first measurements and names
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
    try await StorefrontComparisonHarness.settleInteractions(.cog)
    let count = benchmark.scaledIterations.count
    benchmark.startMeasurement()
    let batch = await StorefrontComparisonHarness.runInteractions(.cog, count)
    benchmark.stopMeasurement()
    await StorefrontComparisonHarness.validateInteractions(.cog, batch)
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
    let catalog = await StorefrontWorkloadInputs.controlCatalog
    benchmark.startMeasurement()
    let result = await StorefrontWorkloadInputs.runComputeControl(catalog: catalog)
    benchmark.stopMeasurement()
    await StorefrontWorkloadInputs.validateComputeControl(result)
  }

  // What a catalog-wide keyed funnel costs to *build and hold*.
  //
  // Use three iterations with no warm-up. Each retains a standard-profile
  // context; `StorefrontHarness.footprintContexts` explains why release would
  // corrupt the next iteration's counts.
  // Three is enough: these are exact interposer counts rather than a sampled
  // distribution, so agreement from p0 to p100 is the result, and disagreement
  // would itself be the finding.
  //
  // Cog-only, and it has no `perf-16` twin: its preparation has to start the
  // catalog and search-index requests while creating none of the funnel, and
  // the neutral protocol has no verb that does that. See
  // `StorefrontComparisonHarness.prepareCogFootprint()`.
  Benchmark(
    "perf-15-storefront-footprint",
    configuration: .init(
      metrics: countingMetrics + [storefrontFootprintStateMetric],
      warmupIterations: 0,
      maxDuration: .seconds(120),
      maxIterations: 3,
      thresholds: reportedOnly.merging([storefrontFootprintStateMetric: BenchmarkThresholds()]) {
        current, _ in current
      }
    )
  ) { benchmark in
    try await StorefrontComparisonHarness.prepareCogFootprint()
    benchmark.startMeasurement()
    let rankedCount = await StorefrontComparisonHarness.materializeFootprint(.cog)
    benchmark.stopMeasurement()
    await StorefrontComparisonHarness.retainFootprint(.cog, rankedCount: rankedCount)
    benchmark.measurement(
      storefrontFootprintStateMetric,
      await StorefrontComparisonHarness.footprintStateCount(.cog)
    )
  }
}

/// The metrics every quiescent Storefront cut reports.
///
/// Shared with the `perf-16` counting cuts rather than repeated there: two
/// families that reported different columns for the same measured region would
/// be describing the same run two ways.
let storefrontCountingMetrics: [BenchmarkMetric] = [
  .mallocCountTotal, .freeCountTotal, .mallocFreeDelta, .mallocBytesCount,
  .memoryLeakedBytes, .objectAllocCount, .retainCount, .releaseCount, .wallClock,
  .instructions,
]

/// The metrics every non-quiescent Storefront cut reports.
///
/// Wall clock, instructions, and resident memory only. Each cut that uses them
/// builds or drives a runtime that starts tasks, accepts async completions, or
/// is dropped at the end of a sample. Per `M5-11`, such regions cannot use ARC
/// or malloc counters. A task can finish after the harness removes its ARC
/// hooks and call a null `swift_release_hook`.
let storefrontTimingMetrics: [BenchmarkMetric] = [
  .wallClock, .cpuTotal, .instructions, .peakMemoryResidentDelta, .peakMemoryResident,
]

/// States one footprint iteration materializes.
///
/// A custom metric because it is a *count of graph states*, which no built-in
/// metric expresses, and because carrying it beside the allocation columns is
/// what lets a reader divide one by the other. Unscaled: the count is the
/// count, not a count per thousand iterations.
let storefrontFootprintStateMetric = BenchmarkMetric.custom(
  "storefrontStates",
  polarity: .prefersSmaller,
  useScalingFactor: false
)

/// The Storefront cuts whose measured region is not quiescent.
let storefrontTimingBenchmarks: @Sendable () -> Void = {
  let timingMetrics = storefrontTimingMetrics
  // Every cut below pins `maxIterations`, and the reason is the memory columns
  // rather than the timing ones. `peakMemoryResident` is a process-wide
  // high-water mark that never comes down, and `peakMemoryResidentDelta` only
  // advances on iterations where that mark moves. Left to a duration budget, a
  // core that is ten times faster runs ten times as many build-and-drop cycles.
  // That gives the allocator more chances to raise the peak, making the memory
  // columns reflect throughput. A fixed iteration count makes them comparable.
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
    benchmark.startMeasurement()
    try await StorefrontComparisonHarness.runColdStart(.cog)
    benchmark.stopMeasurement()
    await StorefrontComparisonHarness.validateMeasuredDriver(.cog)
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
    try await StorefrontComparisonHarness.settleBurst(.cog)
    let input = await StorefrontComparisonHarness.prepareBurst(.cog)
    benchmark.startMeasurement()
    try await StorefrontComparisonHarness.runBurst(.cog, input)
    benchmark.stopMeasurement()
    await StorefrontComparisonHarness.validateBurst(.cog, input)
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
    benchmark.startMeasurement()
    try await StorefrontComparisonHarness.runSession(.cog)
    benchmark.stopMeasurement()
    await StorefrontComparisonHarness.validateMeasuredDriver(.cog)
  }
}
