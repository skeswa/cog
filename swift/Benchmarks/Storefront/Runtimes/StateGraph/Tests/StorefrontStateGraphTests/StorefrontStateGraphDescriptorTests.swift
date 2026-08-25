import StorefrontStateGraph
import StorefrontWorkload
import Testing

/// The independent pin on what the swift-state-graph port declares it
/// guarantees.
///
/// Eight of the trace's checkpoints read
/// ``StateGraphStorefrontRuntime/descriptor``'s semantics rather than integer
/// literals, so that four runtimes can be held to four individually justified
/// sets of numbers. That indirection has a cost this suite exists to pay back:
/// with the literals gone, the cheapest way to green a genuine invalidation
/// regression in this port is a one-character edit to the descriptor, and
/// nothing else in the package would notice.
///
/// So the numbers are pinned here a second time, in a file no checkpoint reads.
/// A regression that changes the port's real behavior fails the trace; a "fix"
/// that edits the descriptor to match the new behavior fails this suite
/// instead. Changing a value below is a deliberate, reviewed statement that the
/// port's guarantees have genuinely changed — accompanied by the justification
/// `swift/Benchmarks/Storefront/Runtimes/StateGraph/README.md` and `docs/swift/impl/perf.md`
/// are both required to carry.
@Suite("swift-state-graph Storefront descriptor")
struct StorefrontStateGraphDescriptorTests {
  /// What the port declares, spelled out field by field.
  ///
  /// Written as a whole-value literal rather than as eight loose constants so
  /// that the pin cannot fall behind the type: `StorefrontRuntimeSemantics` has
  /// only its memberwise initializer, so a field added to it stops compiling
  /// *here* until someone states what this port guarantees for it.
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
  @Test("the port declares exactly the guarantees the trace holds it to")
  func semanticsFieldsAreExactlyDeclared() {
    let semantics = StateGraphStorefrontRuntime.descriptor.semantics

    // One transaction plus one explicit render is one settlement, however many
    // sources the verb wrote.
    #expect(semantics.browseRunsPerContentChangingTurn == 1)
    // `Stored`'s equality gate: writing the value already there invalidates
    // nothing, so the render finds unchanged roots and deposits nothing.
    #expect(semantics.browseRunsPerEqualWrite == 0)
    // `Computed`'s pull-based invalidation: a transaction touching only
    // offscreen inputs reaches no root the render reads.
    #expect(semantics.browseRunsPerUndemandedInvalidation == 0)
    // Registration against the resting signed-out value, then the response.
    #expect(semantics.accountRunsThroughSignIn == 2)
    // The sharpest claim the macrobenchmark makes, and the port makes it in
    // full: an offscreen-only invalidation polls no slot and asks for nothing.
    #expect(semantics.declaredUndemandedRequestStarts == 0)
    // The release sweep is the port's own, because swift-state-graph has no
    // lifetime model — but it is real, so the teardown release proof is too.
    #expect(semantics.releasesUnobservedValues)
    // Staleness is refused by generation. The port never cancels a superseded
    // task; it lets it complete and refuses it.
    #expect(semantics.refusesStaleResultsByGeneration)
    // `refreshRecommendations()` hands back a handle bound to the generation it
    // started, resolved as superseded at the moment of replacement.
    #expect(semantics.hasPerGenerationRefreshHandles)
  }

  @Test("the descriptor as a whole is exactly the pinned value")
  func semanticsMatchThePinnedValueExactly() {
    #expect(StateGraphStorefrontRuntime.descriptor.semantics == Self.expectedSemantics)
  }

  /// The slug is the runtime's identity in every recorded number.
  ///
  /// `perf-16-storefront-<slug>-<cut>` is how a benchmark result is named, and
  /// two numbers are only comparable when they were recorded under the same
  /// slug. Renaming it silently would orphan every figure already written down.
  @Test("the port keeps the identity its recorded numbers are filed under")
  func descriptorIdentityIsStable() {
    #expect(StateGraphStorefrontRuntime.descriptor.slug == "state-graph")
    #expect(StateGraphStorefrontRuntime.descriptor.displayName == "swift-state-graph")
  }

  /// The library version the port's assumptions were confirmed against.
  ///
  /// Pinned in the manifest with `exact:` and repeated on the runtime, because
  /// every claim in `API-NOTES.md` is a claim about this release and a number
  /// recorded against a different one would not be the same measurement.
  @Test("the port reports the library release it was measured against")
  func libraryVersionIsPinned() {
    #expect(StateGraphStorefrontRuntime.stateGraphVersion == "0.28.0")
  }
}
