import StorefrontObservationRaw
import StorefrontWorkload
import Testing

/// The raw `@Observable` port's correctness gate.
///
/// No number this port ever publishes is meaningful unless this suite is green
/// in the same session, which is the whole reason it exists: a floor that
/// computed the wrong answer would be a floor for a different workload. Every
/// expectation here comes from the runtime-neutral shadow ``StorefrontWorld``,
/// derived from the profile and the events the driver issued, and never read
/// back out of the port being measured. Because all four runtimes are checked
/// against that same shadow, a green here is also half of the transitive proof
/// that the four agree with one another, without any test having to link two
/// runtimes at once, which target separation forbids.
///
/// The `smoke` profile throughout: it is the profile the correctness gate is
/// defined on, and it still exercises every structure the reported profile does
///, several categories, a real pricing ladder, a cart with promotions, and both
/// halves of an inventory burst.
///
/// Not `@testable`: this suite holds the port to the public
/// ``StorefrontRuntime`` contract, which is the only surface the trace and the
/// benchmark cuts ever touch.
@Suite("Raw @Observable Storefront runtime")
struct StorefrontObservationRawTests {
  /// The whole eleven-phase interaction trace, checked against the shadow.
  ///
  /// Forty checkpoints, of which exactly one is skipped and the skip is
  /// asserted by name below. `requireSettledOutput()` then re-derives the final
  /// rendered state from the shadow and proves the session ended with no
  /// outstanding requests, a port that had quietly stopped asking for
  /// something would fail there rather than merely being fast.
  @Test("runs the standard interaction trace against the shared shadow")
  func runsTheStandardTrace() async throws {
    let driver = StorefrontSessionDriver<RawObservationStorefrontRuntime>(profile: .smoke)
    try await driver.runStandardTrace()

    for failure in driver.failures {
      Issue.record("checkpoint failed: \(failure.failureDescription)")
    }
    #expect(driver.failures.isEmpty)
    #expect(!driver.checkpoints.isEmpty)
    await driver.requireSettledOutput()
  }

  /// Exactly one claim in the trace does not apply to this port.
  ///
  /// The teardown phase's release proof, because this port declares no lifetime
  /// release: nothing is cached, so re-demanding a row after grace would ask the
  /// service again for the wrong reason. Every other claim, including the burst
  /// phase's offscreen-work claim, which is asserted against a declared number
  /// rather than skipped, is one this port is held to. A second skip appearing
  /// here means a claim stopped being checked.
  @Test("skips exactly the one claim this port does not make")
  func skipsOnlyTheLifetimeReleaseProof() async throws {
    let driver = StorefrontSessionDriver<RawObservationStorefrontRuntime>(profile: .smoke)
    try await driver.runStandardTrace()

    let skipped = driver.checkpoints.filter { $0.expected.hasPrefix("not applicable") }
    #expect(skipped.map(\.name) == ["released row asks again"])
  }

  /// The port's declared semantics, stated here so a change to them is a change
  /// to a test rather than a silent change to what the trace asserts.
  ///
  /// Three values differ from Cog's, and each difference is a result the
  /// comparison exists to surface: this port renders on an equal write and on an
  /// offscreen-only invalidation because it cannot tell that nothing changed,
  /// and it releases nothing because it caches nothing.
  ///
  /// `declaredUndemandedRequestStarts` is zero, matching Cog, but for a
  /// structural reason rather than a state-management one, since the render
  /// walks only the visible window widened by the prefetch margin. The results
  /// table has to say so; this test only fixes the number.
  @Test("declares the semantics the trace holds it to")
  func declaresItsSemantics() {
    let descriptor = RawObservationStorefrontRuntime.descriptor
    #expect(descriptor.slug == "observation-raw")
    #expect(descriptor.displayName == "raw @Observable")

    let semantics = descriptor.semantics
    #expect(semantics.browseRunsPerContentChangingTurn == 1)
    #expect(semantics.browseRunsPerEqualWrite == 1)
    #expect(semantics.browseRunsPerUndemandedInvalidation == 1)
    #expect(semantics.accountRunsThroughSignIn == 2)
    #expect(semantics.declaredUndemandedRequestStarts == 0)
    #expect(semantics.releasesUnobservedValues == false)
    #expect(semantics.refusesStaleResultsByGeneration == true)
    #expect(semantics.hasPerGenerationRefreshHandles == true)
  }

  /// The port reaches the shadow's rendered state at every phase boundary, not
  /// merely at the end of the session.
  ///
  /// A port that diverged in the middle and converged again by the last phase
  /// would pass ``runsTheStandardTrace()`` and still have rendered screens
  /// nobody asked for. Running the phases individually and comparing after each
  /// is what closes that gap.
  ///
  /// The first two boundaries are compared more narrowly, because the shadow is
  /// not yet an oracle for them and pretending otherwise would be checking the
  /// wrong thing. ``StorefrontWorld`` holds the catalog, the search index, and
  /// every fixture response from the moment it is constructed, it models the
  /// *settled* world, whereas the session has released nothing at bootstrap and
  /// has released only its root responses after `rootData`. So bootstrap is
  /// checked for an empty screen, which is the claim the trace itself makes
  /// there, and `rootData` is checked for the visible identifiers only: the
  /// checksum folds in live inventory and personalized offers, whose requests
  /// are still in flight until `initialRowData` drains them.
  @Test("agrees with the shadow at every phase boundary")
  func agreesWithTheShadowAtEveryPhase() async throws {
    let driver = StorefrontSessionDriver<RawObservationStorefrontRuntime>(profile: .smoke)

    try await driver.runBootstrapPhase()
    #expect(driver.sink.visibleProductIDs.isEmpty, "the loading shell rendered rows")

    try await driver.runRootDataPhase()
    expectVisibleProducts(driver, after: .rootData)

    try await driver.runInitialRowDataPhase()
    expectRenderedState(driver, after: .initialRowData)
    try await driver.runScrollPhase()
    expectRenderedState(driver, after: .scroll)
    try await driver.runSearchPhase()
    expectRenderedState(driver, after: .search)
    try await driver.runFilterPhase()
    expectRenderedState(driver, after: .filters)
    try await driver.runCartPhase()
    expectRenderedState(driver, after: .cart)
    try await driver.runDetailPhase()
    expectRenderedState(driver, after: .detail)
    try await driver.runCheckoutPhase()
    expectRenderedState(driver, after: .checkout)
    try await driver.runBurstPhase()
    expectRenderedState(driver, after: .burst)
    try await driver.runTeardownPhase()
    expectRenderedState(driver, after: .teardown)

    #expect(driver.failures.isEmpty)
  }

  /// Compares which products one phase boundary put on screen.
  ///
  /// - Parameters:
  ///   - driver: The session under test.
  ///   - phase: Which boundary this is, so a failure names it.
  private func expectVisibleProducts(
    _ driver: StorefrontSessionDriver<RawObservationStorefrontRuntime>,
    after phase: StorefrontPhase
  ) {
    #expect(
      driver.sink.visibleProductIDs == driver.world.visibleProductIDs,
      "visible products diverged after the \(phase.rawValue) phase"
    )
  }

  /// Compares one phase boundary's whole rendered state with the shadow's.
  ///
  /// The checksum is the order-sensitive fold over every visible row's price,
  /// available units, badges, and cart quantity, so it catches a divergence in
  /// any of the four rather than only in the list order.
  ///
  /// The order total is compared only when the shadow's cart has lines in it,
  /// exactly as ``StorefrontSessionDriver/requireSettledOutput(against:)`` does:
  /// an empty cart is not a shipment, so the shadow's arithmetic and the
  /// runtime's guarded quotes are answering different questions.
  ///
  /// - Parameters:
  ///   - driver: The session under test.
  ///   - phase: Which boundary this is, so a failure names it.
  private func expectRenderedState(
    _ driver: StorefrontSessionDriver<RawObservationStorefrontRuntime>,
    after phase: StorefrontPhase
  ) {
    expectVisibleProducts(driver, after: phase)
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
