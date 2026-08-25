/// Drives the standard interaction trace against one isolated runtime.
///
/// Generic over ``StorefrontRuntime`` so that Cog, raw Swift Observation,
/// hand-memoized Observation, and swift-state-graph run the *same* shopping
/// session rather than four similar ones. Nothing here names a state-management
/// symbol: every user action goes through a named runtime verb, every
/// expectation comes from the runtime-neutral shadow ``StorefrontWorld``, the
/// runtime-neutral ``StorefrontScript``, or the shared ``StorefrontSink``, and
/// every asynchronous step is released by name and awaited on a definite signal
/// the runtime itself gives — so nothing here waits on a duration and nothing
/// polls.
///
/// ## Identity and ownership
///
/// One driver per session. It creates the runtime in ``init(profile:holds:preparedWorld:recordsCheckpoints:grace:)``
/// and retains it for the session's life; the runtime is never replaced. The
/// driver owns the script, the sink, and the shadow world; the runtime owns its
/// own storage, its own asynchronous work, and its own clock. The driver never
/// reaches into the runtime's representation, which is what makes four runtimes
/// comparable rather than merely similar.
///
/// ## Isolation
///
/// MainActor-confined, like every runtime it drives. The trace's suspensions
/// are all awaits on the script actor or on a runtime settlement barrier; every
/// verb and every sink read happens on the MainActor between them.
///
/// ## Turn and settlement ordering
///
/// A verb returns settled, so the trace reads ``sink`` on the line after it.
/// The driver relies on that everywhere and provides no barrier of its own for
/// synchronous work — a runtime that settled lazily could not be driven by this
/// class at all.
///
/// `nonisolated deinit` per the repository convention: under
/// `.defaultIsolation(MainActor.self)` a synthesized deinit would ask the
/// concurrency runtime which executor it is on for every deallocation, and on a
/// *generic* class it also crashes the release-configuration optimizer.
@MainActor
public final class StorefrontSessionDriver<Runtime: StorefrontRuntime> {
  /// The world being driven.
  public let profile: StorefrontProfile

  /// The runtime under measurement.
  public let runtime: Runtime

  /// Durable observers whose settled outputs the driver can validate.
  public let holds: StorefrontHolds

  /// Where held observers deposit what they read.
  public let sink: StorefrontSink

  /// The installed request boundary.
  public let service: StorefrontService

  /// The catalog the fixtures will produce, precomputed for expectations.
  public let catalog: CatalogSnapshot

  /// What the runtime under measurement structurally guarantees.
  ///
  /// Hoisted to a stored property so a phase reads it once rather than
  /// re-entering a static on every checkpoint. Only the eight invalidation
  /// claims consult it; the thirty-one identity, checksum, money, and plan
  /// checkpoints admit no per-runtime variation and read nothing from here.
  public let semantics: StorefrontRuntimeSemantics

  /// Everything the trace claimed, in the order it claimed it.
  public private(set) var checkpoints: [StorefrontCheckpoint] = []

  /// Whether phase checks evaluate and record their expected and actual values.
  ///
  /// Correctness runs leave this enabled. A benchmark may disable it so the
  /// measured region contains the application trace rather than the deliberately
  /// slow shadow verifier, then call ``requireSettledOutput(against:)`` after
  /// stopping measurement to validate the sample's final state and request
  /// quiescence.
  public let recordsCheckpoints: Bool

  /// The shadow model every checkpoint is derived from.
  ///
  /// The driver keeps this in step with the verbs it issues, so an expectation
  /// is always recomputed from the profile and the events rather than read back
  /// out of the runtime being measured.
  public internal(set) var world: StorefrontWorld

  /// The next recency rank to hand out.
  var nextViewRank = 0

  /// Products the session has materialized, in first-seen order.
  public internal(set) var visitedProductIDs: [ProductID] = []

  /// Membership set behind ``visitedProductIDs``.
  var visitedProductIDSet: Set<ProductID> = []

  /// The script behind ``service``.
  ///
  /// `public` because a runtime port's own correctness tests live in another
  /// module and assert on the request ledger this forwards to.
  public var script: StorefrontScript { service.script }

  /// Creates a driver over a fresh isolated runtime.
  ///
  /// The runtime is built last, and it is built with the script and the sink
  /// this driver already owns, so the service installation and the starting row
  /// window settle inside ``StorefrontRuntime/make(profile:service:initialWindow:holds:sink:grace:)``
  /// before anything observes.
  ///
  /// - Parameters:
  ///   - profile: The world to build.
  ///   - holds: Which durable observers the runtime registers.
  ///   - preparedWorld: An immutable fixture-derived world prepared outside a
  ///     measured region. The driver receives a value copy and mutates only it.
  ///   - recordsCheckpoints: Whether phase checks evaluate and record values.
  ///   - grace: How long a value with no observer may survive before release.
  ///     Short by default so the lifetime phase advances an injected clock
  ///     rather than a real one. A runtime with no lifetime model ignores it.
  public init(
    profile: StorefrontProfile,
    holds: StorefrontHolds = .all,
    preparedWorld: StorefrontWorld? = nil,
    recordsCheckpoints: Bool = true,
    grace: Duration = .seconds(30)
  ) {
    self.profile = profile
    self.holds = holds
    self.recordsCheckpoints = recordsCheckpoints
    semantics = Runtime.descriptor.semantics
    let world = preparedWorld ?? StorefrontWorld(profile: profile)
    guard world.profile == profile else {
      fatalError(
        "The Storefront driver received a \(world.profile.name) world for its \(profile.name) profile."
      )
    }
    self.world = world
    catalog = world.catalog
    let service = StorefrontService(profile: profile, mode: .scripted)
    self.service = service
    let sink = StorefrontSink()
    self.sink = sink
    runtime = Runtime.make(
      profile: profile,
      service: service,
      initialWindow: RowWindow(offset: 0, length: profile.viewportRowCount),
      holds: holds,
      sink: sink,
      grace: grace
    )
  }

  // MARK: - Request plumbing

  /// Releases one request and waits for the runtime to finish deciding about it.
  ///
  /// The barrier fires for accepted completions *and* for stale, cancelled,
  /// released, and invalidated ones the runtime drops, so this is a definite
  /// signal even when the completion is refused — which is precisely what the
  /// stale-suggestion step needs.
  ///
  /// - Parameter id: The request to release.
  public func release(_ id: StorefrontRequestID) async throws {
    guard await script.isPending(id) else {
      fatalError(
        """
        The Storefront driver tried to release \(id), which is neither scheduled nor suspended. \
        Awaiting a completion that will never arrive is a hang rather than a failure, so this \
        traps instead: either the graph never demanded that request, or it was already released.
        """
      )
    }
    try await runtime.settlingOneAsyncResult {
      await script.release(id)
    }
  }

  /// Waits until every named request has started.
  ///
  /// - Parameter ids: The requests to wait for.
  public func awaitStarted(_ ids: [StorefrontRequestID]) async {
    await script.awaitStarted(ids)
  }

  /// Releases every scheduled or suspended request, newest first, until none remain.
  ///
  /// Newest first is the deliberate out-of-order rule: the runtime must not be
  /// relying on completions arriving in request order, and releasing in
  /// reverse is the cheapest honest way to prove it is not.
  ///
  /// - Parameter roundLimit: A backstop. Releasing a request may start more, so
  ///   this loop is bounded rather than trusting the runtime to converge.
  @discardableResult
  public func drainRequests(roundLimit: Int = 64) async throws -> Int {
    var released = 0
    for _ in 0..<roundLimit {
      let pending = await script.pendingRequestIDs
      guard !pending.isEmpty else { return released }
      for id in pending.reversed() {
        try await release(id)
        released += 1
      }
    }
    fatalError(
      """
      The Storefront script still had outstanding requests after \(roundLimit) drain rounds, \
      which means releasing a request keeps starting new ones. That is a runaway demand \
      loop in the workload, not a slow benchmark.
      """
    )
  }

  // MARK: - Checkpoints

  /// Records one claim.
  ///
  /// - Parameters:
  ///   - phase: Which phase is claiming it.
  ///   - name: What is being claimed.
  ///   - expected: What should have happened.
  ///   - actual: What did.
  public func check<Expected: CustomStringConvertible, Actual: CustomStringConvertible>(
    phase: String,
    _ name: String,
    expected: @autoclosure () -> Expected,
    actual: @autoclosure () -> Actual
  ) {
    guard recordsCheckpoints else { return }
    checkpoints.append(
      StorefrontCheckpoint(
        phase: phase,
        name: name,
        expected: expected().description,
        actual: actual().description
      )
    )
  }

  /// Records that a claim does not apply to this runtime, and why.
  ///
  /// A skipped checkpoint appears in ``checkpoints`` with `holds == true` and an
  /// explicit reason, so a results table can show "not applicable" rather than a
  /// gap a reader must guess at.
  ///
  /// Because a skip records as holding, it is an opt-out, and there are exactly
  /// **two** legal call sites in the whole trace — the two genuinely optional
  /// claims: the teardown phase's superseded-refresh checkpoint, guarded by
  /// ``StorefrontRuntimeSemantics/hasPerGenerationRefreshHandles``, and the
  /// teardown phase's release proof, guarded by
  /// ``StorefrontRuntimeSemantics/releasesUnobservedValues``. Both are optional
  /// because the assertion is unrunnable without the feature: awaiting a handle
  /// that never resolves on replacement would hang, and a runtime that caches
  /// nothing would re-request the released row for the wrong reason. Every other
  /// claim, the burst phase's offscreen-work claim above all, is a requirement of
  /// every runtime and is asserted against a declared number rather than skipped
  /// — see ``StorefrontRuntimeSemantics/declaredUndemandedRequestStarts``. A
  /// third call site is a review failure, not a new feature.
  ///
  /// - Parameters:
  ///   - phase: Which phase would have claimed it.
  ///   - name: What would have been claimed. Byte-identical to the name the
  ///     asserting branch uses, so a results table lines the two up.
  ///   - reason: Why this runtime is not held to it.
  public func skip(phase: String, _ name: String, because reason: String) {
    guard recordsCheckpoints else { return }
    let notApplicable = "not applicable: \(reason)"
    checkpoints.append(
      StorefrontCheckpoint(
        phase: phase,
        name: name,
        expected: notApplicable,
        actual: notApplicable
      )
    )
  }

  /// Every checkpoint that did not hold.
  public var failures: [StorefrontCheckpoint] {
    checkpoints.filter { !$0.holds }
  }

  /// Traps when any checkpoint failed.
  ///
  /// Correctness runs and benchmark setup call this outside measured regions,
  /// because a workload that computed the wrong answer produces a timing that
  /// means nothing.
  public func requireCheckpointsHold() {
    let failures = failures
    guard failures.isEmpty else {
      fatalError(
        """
        The Storefront session failed \(failures.count) checkpoint(s) before reporting: \
        \(failures.map(\.failureDescription).joined(separator: "; "))
        """
      )
    }
  }

  /// Validates the final rendered output and proves that the sample is quiet.
  ///
  /// This is intentionally separate from ``check(phase:_:expected:actual:)``:
  /// benchmark cuts call it only after stopping their timers. It remains useful
  /// with checkpoint recording disabled because it derives the expected digest
  /// from the driver's independently updated shadow world at the final state.
  ///
  /// Every claim here is runtime-invariant. There is no `semantics` reading in
  /// this method and there must never be one: a runtime that reported different
  /// visible products, a different checksum, different suggestions, or a
  /// different order total would not be running the same session.
  ///
  /// - Parameter expectedWorld: A shadow updated outside the driver, such as
  ///   the interaction cut's post-timing replay. Defaults to the trace's world.
  public func requireSettledOutput(against expectedWorld: StorefrontWorld? = nil) async {
    let expectedWorld = expectedWorld ?? world
    guard expectedWorld.profile == profile else {
      fatalError(
        "The Storefront sample was checked against a \(expectedWorld.profile.name) world for its \(profile.name) profile."
      )
    }
    let expectedIDs = expectedWorld.visibleProductIDs
    guard sink.visibleProductIDs == expectedIDs else {
      fatalError(
        "The Storefront sample settled to \(sink.visibleProductIDs.count) visible products; the shadow expected \(expectedIDs.count)."
      )
    }
    let expectedChecksum = expectedWorld.visibleChecksum
    guard sink.visibleChecksum == expectedChecksum else {
      fatalError(
        "The Storefront sample settled to checksum \(sink.visibleChecksum); the shadow expected \(expectedChecksum)."
      )
    }
    if holds.contains(.search) {
      let normalizedQuery = StorefrontKernels.normalize(expectedWorld.query)
      let expectedSuggestions = StorefrontKernels.suggestions(
        for: normalizedQuery,
        products: expectedWorld.catalog.products,
        count: profile.suggestionCount
      )
      guard sink.suggestions == expectedSuggestions else {
        fatalError(
          "The Storefront sample settled to \(sink.suggestions.count) suggestions; the shadow expected \(expectedSuggestions.count)."
        )
      }
    }
    if holds.contains(.cart), !expectedWorld.cartLines.isEmpty {
      let expectedTotal = expectedWorld.orderTotal()
      guard sink.orderTotal == expectedTotal else {
        fatalError(
          "The Storefront sample settled to order total \(sink.orderTotal.totalCents); the shadow expected \(expectedTotal.totalCents)."
        )
      }
    }
    let outstandingCount = await script.outstandingCount
    guard outstandingCount == 0 else {
      fatalError("The Storefront sample ended with \(outstandingCount) outstanding requests.")
    }
  }

  nonisolated deinit {}
}
