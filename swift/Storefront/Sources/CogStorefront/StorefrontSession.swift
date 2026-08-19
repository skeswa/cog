public import Cog
public import CogTesting

/// The shared vocabulary both drivers speak.
///
/// The headless benchmark and the SwiftUI UI test perform the *same* session,
/// which is only true if both take the query, the cart, and the scroll plan
/// from one place. Everything here is `nonisolated` and pure so the compute-only
/// control can use it too.
public nonisolated enum StorefrontSession {
  /// What the shopper types, one character per domain operation.
  ///
  /// Chosen so that every intermediate prefix matches something: the fixture
  /// vocabulary puts `trail` first among the qualifiers and `shoes` first among
  /// the nouns, so "t", "tr", … each produce a different non-empty candidate
  /// set rather than nine empty ones followed by an answer.
  public static let searchTarget = "trail shoes"

  /// Every prefix of ``searchTarget``, shortest first, excluding the empty one.
  ///
  /// One domain operation per element; a prefix that normalizes to the same
  /// string as its predecessor still costs a turn but starts no new request,
  /// which is the equality gate the search phase is there to exercise.
  public static var searchPrefixes: [String] {
    (1...searchTarget.count).map { String(searchTarget.prefix($0)) }
  }

  /// The distinct normalized queries ``searchPrefixes`` produces.
  ///
  /// The analytically derived expectation for how many suggestion generations
  /// the search phase starts — derived from the query and the normalizer, never
  /// copied from a run.
  public static var distinctNormalizedQueries: [String] {
    var seen: Set<String> = []
    var result: [String] = []
    for prefix in searchPrefixes {
      let normalized = StorefrontKernels.normalize(prefix)
      guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
      result.append(normalized)
    }
    return result
  }

  /// The products the session puts in the cart.
  ///
  /// Spread evenly across the catalog so they land in different categories,
  /// which is what makes the promotion optimizer a decision rather than a sum.
  ///
  /// - Parameters:
  ///   - profile: Supplies how many to choose.
  ///   - catalog: The catalog to choose from.
  /// - Returns: Product identifiers, in the order they are added.
  public static func cartProductIDs(
    for profile: StorefrontProfile,
    catalog: CatalogSnapshot
  ) -> [ProductID] {
    guard !catalog.products.isEmpty else { return [] }
    let stride = max(1, catalog.products.count / (profile.cartProductCount + 1))
    return (1...profile.cartProductCount).map { index in
      ProductID(min(catalog.products.count - 1, index * stride))
    }
  }

  /// The row windows the scroll phase visits, in order.
  ///
  /// Down through the list a viewport at a time until
  /// ``StorefrontProfile/visitedRowCount`` distinct rows have been seen, then
  /// partly back up. Returning is not decoration: scrolling back re-visits rows
  /// whose state already exists, which is a completely different cost from
  /// visiting a row for the first time, and a benchmark that only ever scrolled
  /// down would never measure it.
  ///
  /// - Parameter profile: Supplies the viewport size and the visit target.
  /// - Returns: The windows to apply, in order.
  public static func scrollPlan(for profile: StorefrontProfile) -> [RowWindow] {
    let step = max(1, profile.viewportRowCount / 2)
    var windows: [RowWindow] = []
    var offset = 0
    while offset + profile.viewportRowCount < profile.visitedRowCount {
      offset += step
      windows.append(RowWindow(offset: offset, length: profile.viewportRowCount))
    }
    // Back up by a third of what was covered, which re-materializes rows whose
    // state the downward pass already created.
    let backSteps = max(1, windows.count / 3)
    for _ in 0..<backSteps {
      offset = max(0, offset - step)
      windows.append(RowWindow(offset: offset, length: profile.viewportRowCount))
    }
    return windows
  }

  /// The products the inventory burst touches.
  ///
  /// Half of them are inside the window the burst phase leaves the list on and
  /// half are far outside it, which is what makes "the offscreen half
  /// invalidated nothing on screen" a claim with two sides.
  ///
  /// - Parameters:
  ///   - profile: Supplies how many to touch.
  ///   - visible: The products currently on screen.
  ///   - previouslyVisited: Products the session has already scrolled past. The
  ///     offscreen half is drawn from here rather than from the far end of the
  ///     catalog on purpose: a burst touching products the session never even
  ///     met would be a weaker claim, because it would be trivially true of any
  ///     implementation.
  ///   - demanded: The products whose row state the list currently demands,
  ///     which the offscreen half must avoid.
  /// - Returns: Touched products: the demanded half first, then the undemanded
  ///   half.
  public static func inventoryBurstIDs(
    for profile: StorefrontProfile,
    visible: [ProductID],
    previouslyVisited: [ProductID],
    demanded: [ProductID]
  ) -> [ProductID] {
    let half = profile.inventoryBurstCount / 2
    let onScreen = Array(visible.prefix(half))
    let demandedSet = Set(demanded)
    let offScreen =
      previouslyVisited
      .filter { !demandedSet.contains($0) }
      .prefix(profile.inventoryBurstCount - onScreen.count)
    return onScreen + Array(offScreen)
  }

  /// How the burst splits, so a checkpoint can name each half.
  ///
  /// The split is on the **demanded** set, not the visible one. A product in
  /// the prefetch margin is offscreen to a shopper but demanded by the graph,
  /// and lumping it into the offscreen half would make that half's claim false
  /// for reasons that have nothing to do with Cog.
  ///
  /// - Parameters:
  ///   - burst: What
  ///     ``inventoryBurstIDs(for:visible:previouslyVisited:demanded:)``
  ///     returned.
  ///   - demanded: The products whose row state the list currently demands.
  /// - Returns: The demanded half and the undemanded half.
  public static func splitBurst(
    _ burst: [ProductID],
    demanded: [ProductID]
  ) -> (onScreen: [ProductID], offScreen: [ProductID]) {
    let demandedSet = Set(demanded)
    return (
      burst.filter { demandedSet.contains($0) },
      burst.filter { !demandedSet.contains($0) }
    )
  }
}

/// One thing the session promised, and what actually happened.
///
/// A value rather than an assertion so the same trace can be driven by a
/// benchmark (which preconditions on `holds`) and by a test (which reports each
/// failure individually). Both stringify, because a checkpoint that could only
/// be compared numerically would have to be rewritten for every new claim.
public nonisolated struct StorefrontCheckpoint: Sendable, Equatable {
  /// Which phase of the trace recorded this.
  public let phase: String

  /// What is being claimed.
  public let name: String

  /// What the profile and event semantics say should have happened.
  public let expected: String

  /// What happened.
  public let actual: String

  /// Whether the claim holds.
  public var holds: Bool { expected == actual }

  /// Creates a checkpoint.
  public init(phase: String, name: String, expected: String, actual: String) {
    self.phase = phase
    self.name = name
    self.expected = expected
    self.actual = actual
  }

  /// A one-line description for a failure message.
  public var failureDescription: String {
    "\(phase)/\(name): expected \(expected), got \(actual)"
  }
}

/// Drives the standard interaction trace against one isolated runtime.
///
/// Every user action goes through a named `CogOps` verb, never a primitive, so
/// this driver and the SwiftUI application perform the same operations rather
/// than two similar ones. Every asynchronous step is released by name and
/// awaited on a definite signal — Cog's own async-completion acknowledgement —
/// so nothing here waits on a duration or polls.
///
/// `nonisolated deinit` per the repository convention.
@MainActor
public final class StorefrontSessionDriver {
  /// The world being driven.
  public let profile: StorefrontProfile

  /// The runtime under measurement.
  public let cogs: Cogs

  /// Where held reactions deposit what they read.
  public let sink: StorefrontSink

  /// The clock lifetime work sleeps on.
  public let clock: TestClock

  /// The installed request boundary.
  public let service: StorefrontService

  /// The catalog the fixtures will produce, precomputed for expectations.
  public let catalog: CatalogSnapshot

  /// Everything the trace claimed, in the order it claimed it.
  public private(set) var checkpoints: [StorefrontCheckpoint] = []

  /// The shadow model every checkpoint is derived from.
  ///
  /// The driver keeps this in step with the ops it issues, so an expectation is
  /// always recomputed from the profile and the events rather than read back
  /// out of the graph being measured.
  public internal(set) var world: StorefrontWorld

  /// The next recency rank to hand out.
  var nextViewRank = 0

  /// Products the session has materialized, in first-seen order.
  public internal(set) var visitedProductIDs: [ProductID] = []

  /// Membership set behind ``visitedProductIDs``.
  var visitedProductIDSet: Set<ProductID> = []

  /// The script behind ``service``.
  var script: StorefrontScript { service.script }

  /// Creates a driver over a fresh isolated runtime.
  ///
  /// - Parameters:
  ///   - profile: The world to build.
  ///   - holds: Which durable leases the mechanism registers.
  ///   - grace: The `whileObserved` grace the runtime uses. Short by default so
  ///     the lifetime phase advances a test clock rather than a real one.
  public init(
    profile: StorefrontProfile,
    holds: StorefrontMechanism.Holds = .all,
    grace: Duration = .seconds(30)
  ) {
    self.profile = profile
    world = StorefrontWorld(profile: profile)
    catalog = StorefrontFixtures.catalog(for: profile)
    let clock = TestClock()
    self.clock = clock
    let service = StorefrontService(profile: profile, mode: .scripted)
    self.service = service
    let sink = StorefrontSink()
    self.sink = sink
    cogs = Cogs.forTesting(
      clock: clock,
      whileObservedGrace: grace,
      mechanisms: [
        StorefrontMechanism(
          service: service,
          initialWindow: RowWindow(offset: 0, length: profile.viewportRowCount),
          holds: holds,
          sink: sink
        )
      ]
    )
  }

  // MARK: - Request plumbing

  /// Releases one request and waits for the graph to finish deciding about it.
  ///
  /// The acknowledgement fires for accepted completions *and* for stale,
  /// cancelled, released, and invalidated ones Cog drops, so this is a definite
  /// signal even when the completion is refused — which is precisely what the
  /// stale-suggestion step needs.
  ///
  /// - Parameter id: The request to release.
  public func release(_ id: StorefrontRequestID) async throws {
    guard await script.isSuspended(id) else {
      fatalError(
        """
        The Storefront driver tried to release \(id), which is not suspended. Awaiting a         completion that will never arrive is a hang rather than a failure, so this traps         instead: either the graph never demanded that request, or it was already released.
        """
      )
    }
    let acknowledged = MainActorCleanupAcknowledgement()
    cogs.acknowledgeNextAsyncCompletionCheck(with: acknowledged)
    await script.release(id)
    try await acknowledged.wait()
  }

  /// Waits until every named request has started.
  ///
  /// - Parameter ids: The requests to wait for.
  public func awaitStarted(_ ids: [StorefrontRequestID]) async {
    await script.awaitStarted(ids)
  }

  /// Releases every suspended request, newest first, until none remain.
  ///
  /// Newest first is the deliberate out-of-order rule: the graph must not be
  /// relying on completions arriving in request order, and releasing in
  /// reverse is the cheapest honest way to prove it is not.
  ///
  /// - Parameter roundLimit: A backstop. Releasing a request may start more, so
  ///   this loop is bounded rather than trusting the graph to converge.
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
      The Storefront script still had suspended requests after \(roundLimit) drain rounds, \
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
  public func check(
    phase: String,
    _ name: String,
    expected: some CustomStringConvertible,
    actual: some CustomStringConvertible
  ) {
    checkpoints.append(
      StorefrontCheckpoint(
        phase: phase,
        name: name,
        expected: expected.description,
        actual: actual.description
      )
    )
  }

  /// Every checkpoint that did not hold.
  public var failures: [StorefrontCheckpoint] {
    checkpoints.filter { !$0.holds }
  }

  /// Traps when any checkpoint failed.
  ///
  /// Benchmarks call this before reporting a number, because a workload that
  /// computed the wrong answer produces a timing that means nothing.
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

  nonisolated deinit {}
}
