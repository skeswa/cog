import StorefrontWorkload
import Testing

@testable import CogStorefront

/// The independent pin on what Cog declares it guarantees.
///
/// Eight of the trace's checkpoints once carried integer literals written into
/// `StorefrontTrace` itself. They now read
/// ``CogStorefrontRuntime/descriptor``'s semantics instead, so that the same
/// script can hold four runtimes to four different, and individually
/// justified, sets of numbers. That indirection has a cost this suite exists
/// to pay back: with the literals gone, the cheapest way to green a genuine Cog
/// invalidation regression became a one-character edit to the descriptor, and
/// nothing in either package would have noticed.
///
/// So the numbers are pinned here, a second time, in a file no checkpoint
/// reads. A regression that changes Cog's real behavior now fails the trace; a
/// "fix" that edits the descriptor to match the new behavior fails this suite
/// instead. Changing a value below is therefore a deliberate, reviewed
/// statement that Cog's guarantees have genuinely changed, accompanied by the
/// justification `swift/Benchmarks/Storefront/Workload/README.md` and `docs/swift/impl/perf.md`
/// are both required to carry, and never a convenient way to make a failing
/// checkpoint pass.
@Suite("Cog Storefront descriptor")
struct CogStorefrontDescriptorTests {
  /// What Cog declares, spelled out field by field.
  ///
  /// Written as a whole-value literal rather than as eight loose constants so
  /// that the pin cannot fall behind the type: `StorefrontRuntimeSemantics` has
  /// only its memberwise initializer, so a field added to it stops compiling
  /// *here* until someone states what Cog guarantees for it. A pin that checked
  /// a hand-picked subset would silently stop covering whatever was added next.
  static let expectedSemantics = StorefrontRuntimeSemantics(
    browseRunsPerContentChangingTurn: 1,
    browseRunsPerEqualWrite: 0,
    browseRunsPerUndemandedInvalidation: 0,
    accountRunsThroughSignIn: 2,
    declaredUndemandedRequestStarts: 0,
    releasesUnobservedValues: true,
    refusesStaleResultsByGeneration: true,
    hasPerGenerationRefreshHandles: true
  )

  /// Each field on its own line, so a drift reports *which* guarantee moved.
  ///
  /// The whole-value comparison below is the exhaustive check; these are the
  /// legible ones. Both are wanted: equality catches a field this suite forgot,
  /// and the individual expectations turn "the descriptor differs" into "Cog now
  /// claims two browse runs per content-changing turn".
  @Test("Cog declares exactly the guarantees the trace holds it to")
  func semanticsFieldsAreExactlyDeclared() {
    let semantics = CogStorefrontRuntime.descriptor.semantics

    // One settlement per transaction: a turn coalesces, however many sources it
    // wrote.
    #expect(semantics.browseRunsPerContentChangingTurn == 1)
    // An equality gate on sources: writing the current value renders nothing.
    #expect(semantics.browseRunsPerEqualWrite == 0)
    // Demand-driven invalidation: a transaction touching only offscreen inputs
    // runs no held reaction.
    #expect(semantics.browseRunsPerUndemandedInvalidation == 0)
    // Registration against the resting signed-out value, then the response.
    #expect(semantics.accountRunsThroughSignIn == 2)
    // The sharpest claim the macrobenchmark makes: offscreen invalidation asks
    // the service for nothing at all.
    #expect(semantics.declaredUndemandedRequestStarts == 0)
    // Cog has a lifetime model, so the teardown release proof is real.
    #expect(semantics.releasesUnobservedValues)
    // Staleness is refused by generation, not by relying on cancellation.
    #expect(semantics.refusesStaleResultsByGeneration)
    // `refresh` hands back a handle bound to the generation it started.
    #expect(semantics.hasPerGenerationRefreshHandles)
  }

  @Test("the descriptor as a whole is exactly the pinned value")
  func semanticsMatchThePinnedValueExactly() {
    #expect(CogStorefrontRuntime.descriptor.semantics == Self.expectedSemantics)
  }

  /// The slug is the runtime's identity in every recorded number.
  ///
  /// `perf-16-storefront-<slug>-<cut>` is how a benchmark result is named, and
  /// two numbers are only comparable when they were recorded under the same
  /// slug. Renaming it silently would orphan every figure already written down,
  /// so the name is pinned beside the guarantees.
  @Test("the Cog runtime keeps the identity its recorded numbers were filed under")
  func descriptorIdentityIsStable() {
    #expect(CogStorefrontRuntime.descriptor.slug == "cog")
    #expect(CogStorefrontRuntime.descriptor.displayName == "Cog")
  }
}
