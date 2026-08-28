import StorefrontObservationMemo
import StorefrontWorkload
import Testing

/// The hand-memoized `@Observable` port's correctness gate.
///
/// No number this port publishes means anything unless this suite is green in
/// the same session. That matters more here than for the floor: this port's
/// whole claim is that hand-written caching with hand-written invalidation can
/// reproduce a fine-grained graph's *behavior*, so a stale cache would not merely
/// make it slow, it would make the comparison a comparison of two different
/// sessions. Every expectation comes from the runtime-neutral shadow
/// ``StorefrontWorld``, derived from the profile and the events the driver
/// issued, and never read back out of the port being measured.
///
/// The `smoke` profile throughout, for the reason the raw port's suite records:
/// it is the profile the correctness gate is defined on and it still exercises
/// every structure the reported profile does.
///
/// Not `@testable`: this suite holds the port to the public
/// ``StorefrontRuntime`` contract, which is the only surface the trace and the
/// benchmark cuts ever touch.
@Suite("Hand-memoized @Observable Storefront runtime")
struct StorefrontObservationMemoTests {
  /// The whole eleven-phase interaction trace, checked against the shadow.
  ///
  /// `requireSettledOutput()` then re-derives the final rendered state from the
  /// shadow and proves the session ended with no outstanding requests, a port
  /// whose caches had quietly stopped it asking for something would fail there
  /// rather than merely looking fast.
  @Test("runs the standard interaction trace against the shared shadow")
  func runsTheStandardTrace() async throws {
    let driver = StorefrontSessionDriver<MemoObservationStorefrontRuntime>(profile: .smoke)
    try await driver.runStandardTrace()

    for failure in driver.failures {
      Issue.record("checkpoint failed: \(failure.failureDescription)")
    }
    #expect(driver.failures.isEmpty)
    #expect(!driver.checkpoints.isEmpty)
    await driver.requireSettledOutput()
  }

  /// This port skips nothing, and that is the sharp claim.
  ///
  /// The trace's two optional claims exist for runtimes that hand back no
  /// per-generation refresh handle and hold no lifetime model. This port
  /// declares both, so both are asserted, and because a skip records as
  /// holding, a "every checkpoint holds" loop could never notice one appearing.
  /// If the port ever stopped resolving a replaced demand or stopped releasing
  /// an unobserved row, this test is what fails.
  @Test("is held to every claim the trace can make")
  func skipsNoCheckpoint() async throws {
    let driver = StorefrontSessionDriver<MemoObservationStorefrontRuntime>(profile: .smoke)
    try await driver.runStandardTrace()

    let skipped = driver.checkpoints.filter { $0.expected.hasPrefix("not applicable") }
    #expect(skipped.isEmpty, "the memo port skipped \(skipped.map(\.name))")
    #expect(driver.checkpoints.contains { $0.name == "superseded refresh" })
    #expect(driver.checkpoints.contains { $0.name == "released row asks again" })
  }

  /// The port's declared semantics, stated here so a change to them is a change
  /// to a test rather than a silent change to what the trace asserts.
  ///
  /// Every value matches Cog's, which is this port's central result: a careful
  /// team *can* hand-write its way to the same observable behavior. What the
  /// comparison then reports is what that cost, in wall clock, in allocation,
  /// and in the lines of invalidation code the port's `README.md` counts.
  @Test("declares the semantics the trace holds it to")
  func declaresItsSemantics() {
    let descriptor = MemoObservationStorefrontRuntime.descriptor
    #expect(descriptor.slug == "observation-memo")
    #expect(descriptor.displayName == "hand-memoized @Observable")

    let semantics = descriptor.semantics
    #expect(semantics.browseRunsPerContentChangingTurn == 1)
    #expect(semantics.browseRunsPerEqualWrite == 0)
    #expect(semantics.browseRunsPerUndemandedInvalidation == 0)
    #expect(semantics.accountRunsThroughSignIn == 2)
    #expect(semantics.declaredUndemandedRequestStarts == 0)
    #expect(semantics.releasesUnobservedValues == true)
    #expect(semantics.refusesStaleResultsByGeneration == true)
    #expect(semantics.hasPerGenerationRefreshHandles == true)
  }

  /// The port reaches the shadow's rendered state at every phase boundary, not
  /// merely at the end of the session.
  ///
  /// The failure this catches is the characteristic failure of hand-written
  /// invalidation: a cache that goes stale in the middle of a session and is
  /// cleared later by something unrelated. Such a port passes an end-of-session
  /// assertion and has still shown the shopper a wrong price for six
  /// interactions.
  @Test("agrees with the shadow at every phase boundary")
  func agreesWithTheShadowAtEveryPhase() async throws {
    let driver = StorefrontSessionDriver<MemoObservationStorefrontRuntime>(profile: .smoke)

    // No agreement is claimed before the root responses land, and claiming one
    // would be wrong rather than strict: the shadow is a fully materialized
    // world from the moment it is constructed, while a correct runtime has an
    // empty catalog until the catalog request is released. The trace's own
    // bootstrap checkpoints assert the *loading shell* instead.
    try await driver.runBootstrapPhase()
    try await driver.runRootDataPhase()
    // The catalog and index settle visible IDs. The digest still needs row
    // inventory and offers, while the shadow assumes all fixtures resolved.
    expectVisibleIdentitiesAgree(driver, after: .rootData)
    try await driver.runInitialRowDataPhase()
    expectAgreement(driver, after: .initialRowData)
    try await driver.runScrollPhase()
    expectAgreement(driver, after: .scroll)
    try await driver.runSearchPhase()
    expectAgreement(driver, after: .search)
    try await driver.runFilterPhase()
    expectAgreement(driver, after: .filters)
    try await driver.runCartPhase()
    expectAgreement(driver, after: .cart)
    try await driver.runDetailPhase()
    expectAgreement(driver, after: .detail)
    try await driver.runCheckoutPhase()
    expectAgreement(driver, after: .checkout)
    try await driver.runBurstPhase()
    expectAgreement(driver, after: .burst)
    try await driver.runTeardownPhase()
    expectAgreement(driver, after: .teardown)

    #expect(driver.failures.isEmpty)
  }

  /// A standard-profile cold start, which is where this port's caches are
  /// coldest and its funnel widest.
  ///
  /// The whole standard trace is a benchmark's job, not a debug unit suite's.
  /// The cold start is cheap enough to run here and is the part most likely to
  /// expose a cache built from inputs that had not landed yet: the first
  /// viewport materializes against an empty catalog, an empty index, and no
  /// shopper, and every one of those is replaced before the phase ends.
  @Test("a standard cold start holds every checkpoint")
  func standardColdStartHoldsEveryCheckpoint() async throws {
    let driver = StorefrontSessionDriver<MemoObservationStorefrontRuntime>(profile: .standard)
    try await driver.runColdStart()

    for failure in driver.failures {
      Issue.record("checkpoint failed: \(failure.failureDescription)")
    }
    #expect(driver.failures.isEmpty)
    #expect(driver.sink.visibleProductIDs.count == StorefrontProfile.standard.viewportRowCount)
  }

  /// Compares one phase boundary's rendered state with the shadow's.
  ///
  /// The order total is compared only when the shadow's cart has lines in it,
  /// exactly as ``StorefrontSessionDriver/requireSettledOutput(against:)`` does:
  /// an empty cart is not a shipment, so the shadow's arithmetic and the
  /// runtime's guarded quotes are answering different questions.
  ///
  /// - Parameters:
  ///   - driver: The session under test.
  ///   - phase: Which boundary this is, so a failure names it.
  private func expectVisibleIdentitiesAgree(
    _ driver: StorefrontSessionDriver<MemoObservationStorefrontRuntime>,
    after phase: StorefrontPhase
  ) {
    #expect(
      driver.sink.visibleProductIDs == driver.world.visibleProductIDs,
      "visible products diverged after the \(phase.rawValue) phase"
    )
  }

  /// Compares one phase boundary's whole rendered state with the shadow's.
  ///
  /// - Parameters:
  ///   - driver: The session under test.
  ///   - phase: Which boundary this is, so a failure names it.
  private func expectAgreement(
    _ driver: StorefrontSessionDriver<MemoObservationStorefrontRuntime>,
    after phase: StorefrontPhase
  ) {
    expectVisibleIdentitiesAgree(driver, after: phase)
    #expect(
      driver.sink.visibleChecksum == driver.world.visibleChecksum,
      "visible checksum diverged after the \(phase.rawValue) phase"
    )
    guard !driver.world.cartLines.isEmpty else { return }
    #expect(
      driver.sink.orderTotal == driver.world.orderTotal(),
      "order total diverged after the \(phase.rawValue) phase"
    )
  }
}
