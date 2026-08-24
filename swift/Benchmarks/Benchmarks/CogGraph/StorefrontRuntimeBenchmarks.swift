import Benchmark
internal import Cog
internal import CogStorefront
internal import StorefrontObservationMemo
internal import StorefrontObservationRaw
internal import StorefrontStateGraph
internal import StorefrontWorkload

/// The four runtimes the Storefront comparison covers.
///
/// Nonisolated so the `@Sendable` registration closure can iterate it; the
/// harness behind each case is MainActor-isolated, per the shim
/// `swift/Benchmarks/README.md` records.
///
/// The raw value is the runtime's benchmark-name slug, and it is the same slug
/// ``StorefrontRuntimeDescriptor/slug`` carries — ``requireSlugsAgree()``
/// proves that rather than trusting it, because a name that drifted from the
/// runtime it names would mislabel every recorded number.
nonisolated enum StorefrontRuntimeBackend: String, Sendable, CaseIterable {
  /// Cog, the reference implementation.
  case cog

  /// Raw Swift Observation, recomputing on every read — the hardware floor.
  case observationRaw = "observation-raw"

  /// Swift Observation with hand-written memoization — the realistic
  /// competitor.
  case observationMemo = "observation-memo"

  /// swift-state-graph 0.28.0.
  case stateGraph = "state-graph"
}

/// One MainActor harness per runtime, and the only way a benchmark body reaches
/// them.
///
/// Every entry point is `static`, takes a ``StorefrontRuntimeBackend`` plus
/// `Sendable` arguments, and returns `Sendable` values or nothing. That shape is
/// forced rather than stylistic: `Benchmark` is not `Sendable` and upstream's
/// registration closure is nonisolated, so a harness — which owns a live
/// runtime — can never cross back out. Dispatching on the backend inside this
/// type keeps every non-`Sendable` value on the MainActor and lets only `Int`s
/// and plain structs pass between them (`M5-05bb`).
///
/// The four harnesses are the same generic ``StorefrontHarness`` at four
/// concrete `Runtime` bindings, so all four runtimes are measured through
/// literally the same source. `perf-15`'s Cog-only cuts come through here at
/// `.cog` as well, which is why `perf-15-storefront-cold` and
/// `perf-16-storefront-cog-cold` should agree: they are the same code measuring
/// the same runtime, and a disagreement between them is a finding about the
/// apparatus rather than about Cog.
@MainActor
enum StorefrontComparisonHarness {
  /// The Cog harness, shared with the `perf-15` family.
  static let cog = StorefrontHarness<CogStorefrontRuntime>()

  /// The raw `@Observable` harness.
  static let observationRaw = StorefrontHarness<RawObservationStorefrontRuntime>()

  /// The hand-memoized `@Observable` harness.
  static let observationMemo = StorefrontHarness<MemoObservationStorefrontRuntime>()

  /// The swift-state-graph harness.
  static let stateGraph = StorefrontHarness<StateGraphStorefrontRuntime>()

  // MARK: - Naming

  /// Proves each backend's benchmark-name slug is the slug its runtime
  /// declares.
  ///
  /// Called once from every cut's preparation. It costs a string comparison and
  /// it removes an entire class of silent error: a `perf-16-storefront-…` name
  /// is only meaningful if the runtime behind it is the one the name says, and
  /// nothing else in the pipeline would notice if two cases were transposed
  /// here.
  static func requireSlugsAgree() {
    for backend in StorefrontRuntimeBackend.allCases {
      let declared = declaredSlug(backend)
      guard declared == backend.rawValue else {
        fatalError(
          """
          The Storefront comparison registers \(backend.rawValue) against a runtime that calls \
          itself \(declared). Every number recorded under that name would be attributed to the \
          wrong runtime.
          """
        )
      }
    }
  }

  /// The slug the runtime behind one backend declares for itself.
  private static func declaredSlug(_ backend: StorefrontRuntimeBackend) -> String {
    switch backend {
    case .cog: CogStorefrontRuntime.descriptor.slug
    case .observationRaw: RawObservationStorefrontRuntime.descriptor.slug
    case .observationMemo: MemoObservationStorefrontRuntime.descriptor.slug
    case .stateGraph: StateGraphStorefrontRuntime.descriptor.slug
    }
  }

  // MARK: - Cold start and whole session

  /// Builds a runtime and materializes the first complete screen.
  static func runColdStart(_ backend: StorefrontRuntimeBackend) async throws {
    requireSlugsAgree()
    switch backend {
    case .cog: try await cog.runColdStart()
    case .observationRaw: try await observationRaw.runColdStart()
    case .observationMemo: try await observationMemo.runColdStart()
    case .stateGraph: try await stateGraph.runColdStart()
    }
  }

  /// Runs the complete standard interaction trace.
  static func runSession(_ backend: StorefrontRuntimeBackend) async throws {
    requireSlugsAgree()
    switch backend {
    case .cog: try await cog.runSession()
    case .observationRaw: try await observationRaw.runSession()
    case .observationMemo: try await observationMemo.runSession()
    case .stateGraph: try await stateGraph.runSession()
    }
  }

  /// Validates the last measured driver after its timer has stopped.
  ///
  /// The correctness gate every timed cut ends on: the visible identifiers, the
  /// rendered checksum, the suggestions, the order total, and that the scripted
  /// service has nothing outstanding. None of it admits per-runtime variation.
  static func validateMeasuredDriver(_ backend: StorefrontRuntimeBackend) async {
    switch backend {
    case .cog: await cog.validateMeasuredDriver()
    case .observationRaw: await observationRaw.validateMeasuredDriver()
    case .observationMemo: await observationMemo.validateMeasuredDriver()
    case .stateGraph: await stateGraph.validateMeasuredDriver()
    }
  }

  // MARK: - Quiescent interactions

  /// Builds and settles one backend's interaction runtime exactly once.
  static func settleInteractions(_ backend: StorefrontRuntimeBackend) async throws {
    requireSlugsAgree()
    switch backend {
    case .cog: try await cog.settleInteractions()
    case .observationRaw: try await observationRaw.settleInteractions()
    case .observationMemo: try await observationMemo.settleInteractions()
    case .stateGraph: try await stateGraph.settleInteractions()
    }
  }

  /// Drives `count` steady interactions against the settled runtime.
  static func runInteractions(
    _ backend: StorefrontRuntimeBackend,
    _ count: Int
  ) -> StorefrontInteractionBatch {
    switch backend {
    case .cog: cog.runInteractions(count)
    case .observationRaw: observationRaw.runInteractions(count)
    case .observationMemo: observationMemo.runInteractions(count)
    case .stateGraph: stateGraph.runInteractions(count)
    }
  }

  /// Replays a measured batch into the shadow and validates the settled output.
  static func validateInteractions(
    _ backend: StorefrontRuntimeBackend,
    _ batch: StorefrontInteractionBatch
  ) async {
    switch backend {
    case .cog: await cog.validateInteractions(batch)
    case .observationRaw: await observationRaw.validateInteractions(batch)
    case .observationMemo: await observationMemo.validateInteractions(batch)
    case .stateGraph: await stateGraph.validateInteractions(batch)
    }
  }

  // MARK: - Async burst

  /// Builds and settles one backend's burst runtime exactly once.
  static func settleBurst(_ backend: StorefrontRuntimeBackend) async throws {
    requireSlugsAgree()
    switch backend {
    case .cog: try await cog.settleBurst()
    case .observationRaw: try await observationRaw.settleBurst()
    case .observationMemo: try await observationMemo.settleBurst()
    case .stateGraph: try await stateGraph.settleBurst()
    }
  }

  /// Snapshots one burst's inputs outside the measured region.
  static func prepareBurst(_ backend: StorefrontRuntimeBackend) -> StorefrontBurstInput {
    switch backend {
    case .cog: cog.prepareBurst()
    case .observationRaw: observationRaw.prepareBurst()
    case .observationMemo: observationMemo.prepareBurst()
    case .stateGraph: stateGraph.prepareBurst()
    }
  }

  /// Publishes one inventory burst, accepts every response, and settles.
  static func runBurst(
    _ backend: StorefrontRuntimeBackend,
    _ input: StorefrontBurstInput
  ) async throws {
    switch backend {
    case .cog: try await cog.runBurst(input)
    case .observationRaw: try await observationRaw.runBurst(input)
    case .observationMemo: try await observationMemo.runBurst(input)
    case .stateGraph: try await stateGraph.runBurst(input)
    }
  }

  /// Validates a measured inventory burst after its timer has stopped.
  static func validateBurst(
    _ backend: StorefrontRuntimeBackend,
    _ input: StorefrontBurstInput
  ) async {
    switch backend {
    case .cog: await cog.validateBurst(input)
    case .observationRaw: await observationRaw.validateBurst(input)
    case .observationMemo: await observationMemo.validateBurst(input)
    case .stateGraph: await stateGraph.validateBurst(input)
    }
  }

  // MARK: - Footprint

  /// Builds a Cog context and settles its async roots, materializing no keyed
  /// state.
  ///
  /// The root demand is written here, against the concrete
  /// `CogStorefrontRuntime`, because it is the one step of the footprint cut
  /// that no neutral verb expresses. The read is deliberately the *candidate
  /// list* — the last node upstream of the keyed funnel. It pulls the catalog
  /// and the search index and produces a list of ordinals, and it creates not
  /// one per-product state, which is what leaves the whole funnel for the
  /// measured region.
  ///
  /// Tracked, never `peek`: a one-shot peek renews a `whileObserved` grace
  /// sleeper, which is a task and an allocation, and this cut exists to count
  /// allocations.
  ///
  /// This is why the footprint cut has no `perf-16` twin. Every other cut's
  /// preparation is expressible in ``StorefrontRuntime`` verbs;
  /// this one needs "start the catalog and the search index while materializing
  /// none of the funnel", and the protocol has no verb for it —
  /// ``StorefrontRuntime/demandRankedProductIDs()`` materializes exactly the
  /// funnel the measured region is supposed to build.
  static func prepareCogFootprint() async throws {
    requireSlugsAgree()
    try await cog.prepareFootprint { runtime in
      blackHole(runtime.cogs[storefrontSearchCandidateIDsCog].count)
    }
  }

  /// Materializes the catalog-wide keyed funnel, and nothing else.
  static func materializeFootprint(_ backend: StorefrontRuntimeBackend) -> Int {
    switch backend {
    case .cog: cog.materializeFootprint()
    case .observationRaw: observationRaw.materializeFootprint()
    case .observationMemo: observationMemo.materializeFootprint()
    case .stateGraph: stateGraph.materializeFootprint()
    }
  }

  /// Checks the materialization and retains the context so nothing is released.
  static func retainFootprint(_ backend: StorefrontRuntimeBackend, rankedCount: Int) {
    switch backend {
    case .cog: cog.retainFootprint(rankedCount: rankedCount)
    case .observationRaw: observationRaw.retainFootprint(rankedCount: rankedCount)
    case .observationMemo: observationMemo.retainFootprint(rankedCount: rankedCount)
    case .stateGraph: stateGraph.retainFootprint(rankedCount: rankedCount)
    }
  }

  /// The keyed and keyless states one footprint iteration creates.
  static func footprintStateCount(_ backend: StorefrontRuntimeBackend) -> Int {
    switch backend {
    case .cog: cog.footprintStateCount
    case .observationRaw: observationRaw.footprintStateCount
    case .observationMemo: observationMemo.footprintStateCount
    case .stateGraph: stateGraph.footprintStateCount
    }
  }
}

/// The counting half of the cross-runtime comparison.
///
/// Every cut here is quiescent: it neither drops a runtime nor lets a task
/// complete inside the measured region, which is `M5-11`'s rule for a
/// process-wide allocation counter. Registered with the other counting
/// benchmarks and ahead of anything that drops a runtime.
///
/// Reported, never gated — and unlike the `perf-15` family that is a permanent
/// property rather than a stage. No `perf-16` name appears in
/// `THRESHOLDED_BENCHMARKS`, because three of the four runtimes measured here
/// are somebody else's code: gating their numbers would let an upstream release
/// break Cog's CI, which is a comparison holding a project hostage rather than
/// informing it.
let storefrontRuntimeCountingBenchmarks: @Sendable () -> Void = {
  let countingMetrics = storefrontCountingMetrics
  let reported = BenchmarkThresholds()
  let reportedOnly = Dictionary(uniqueKeysWithValues: countingMetrics.map { ($0, reported) })

  for backend in StorefrontRuntimeBackend.allCases {
    Benchmark(
      "perf-16-storefront-\(backend.rawValue)-interactions",
      configuration: .init(
        metrics: countingMetrics,
        warmupIterations: 2,
        maxDuration: .seconds(3),
        thresholds: reportedOnly
      )
    ) { benchmark in
      try await StorefrontComparisonHarness.settleInteractions(backend)
      let count = benchmark.scaledIterations.count
      benchmark.startMeasurement()
      let batch = await StorefrontComparisonHarness.runInteractions(backend, count)
      benchmark.stopMeasurement()
      await StorefrontComparisonHarness.validateInteractions(backend, batch)
    }
  }
}

/// The timing half of the cross-runtime comparison.
///
/// Registered after every counting benchmark, because these cuts drop runtimes
/// and let tasks complete, and the malloc and ARC counters are process-wide.
let storefrontRuntimeTimingBenchmarks: @Sendable () -> Void = {
  let timingMetrics = storefrontTimingMetrics
  let reported = BenchmarkThresholds()
  let reportedOnly = Dictionary(uniqueKeysWithValues: timingMetrics.map { ($0, reported) })

  for backend in StorefrontRuntimeBackend.allCases {
    Benchmark(
      "perf-16-storefront-\(backend.rawValue)-cold",
      configuration: .init(
        metrics: timingMetrics,
        warmupIterations: 1,
        maxDuration: .seconds(120),
        maxIterations: 10,
        thresholds: reportedOnly
      )
    ) { benchmark in
      benchmark.startMeasurement()
      try await StorefrontComparisonHarness.runColdStart(backend)
      benchmark.stopMeasurement()
      await StorefrontComparisonHarness.validateMeasuredDriver(backend)
    }

    Benchmark(
      "perf-16-storefront-\(backend.rawValue)-session",
      configuration: .init(
        metrics: timingMetrics,
        warmupIterations: 1,
        maxDuration: .seconds(180),
        maxIterations: 3,
        thresholds: reportedOnly
      )
    ) { benchmark in
      benchmark.startMeasurement()
      try await StorefrontComparisonHarness.runSession(backend)
      benchmark.stopMeasurement()
      await StorefrontComparisonHarness.validateMeasuredDriver(backend)
    }

    Benchmark(
      "perf-16-storefront-\(backend.rawValue)-async-burst",
      configuration: .init(
        metrics: timingMetrics,
        warmupIterations: 1,
        maxDuration: .seconds(120),
        maxIterations: 50,
        thresholds: reportedOnly
      )
    ) { benchmark in
      try await StorefrontComparisonHarness.settleBurst(backend)
      let input = await StorefrontComparisonHarness.prepareBurst(backend)
      benchmark.startMeasurement()
      try await StorefrontComparisonHarness.runBurst(backend, input)
      benchmark.stopMeasurement()
      await StorefrontComparisonHarness.validateBurst(backend, input)
    }
  }
}
