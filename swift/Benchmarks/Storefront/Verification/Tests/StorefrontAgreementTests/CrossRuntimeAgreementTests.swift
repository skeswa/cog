import CogStorefront
import StorefrontObservationMemo
import StorefrontObservationRaw
import StorefrontStateGraph
import StorefrontWorkload
import Testing

/// The cross-runtime agreement gate: four runtimes, one script, one set of
/// answers.
///
/// This is the strongest correctness gate the Storefront macrobenchmark has, and
/// it is the one every published number rests on. Each runtime's own package
/// already proves that runtime agrees with the shared shadow, which is a
/// *transitive* argument that the four agree with one another. This suite makes
/// the argument directly: it links all four, runs the identical eleven-phase
/// trace against each, and compares their settled answers value for value.
/// Without it, a fast number might simply be a wrong number, and the whole
/// purpose of the comparison is to say that Cog is faster at computing the same
/// thing, not that it is faster at computing something else.
///
/// ## Why it lives in `cog-storefront-verification`
///
/// Because nowhere else can hold it. `cog-storefront` cannot see the ports;
/// `cog-storefront-observation` and `cog-storefront-state-graph` cannot see each
/// other, deliberately, since target separation is what makes it a compile error
/// for one port to reach into another's cache. This package already depends on
/// all four, so it is the one place the four coexist without weakening that
/// separation, and it depends on none of the harness here, because a
/// correctness proof has no business importing a benchmark runner.
///
/// ## What is compared, and what is deliberately not
///
/// Compared: the products on screen, the order-sensitive digest of what those
/// rows rendered, the settled suggestions, the cart's money, and the number of
/// requests still outstanding. Those are properties of the shopping session, so
/// four runtimes running one script owe identical answers.
///
/// Not compared: run counts, cache sizes, node counts, and every other figure
/// that is a property of the implementation strategy. Those are what the
/// benchmark measures and what ``StorefrontRuntimeSemantics`` exists to declare;
/// a suite that required them to match would fail four ways for three correct
/// reasons and one real one.
///
/// ## The `smoke` profile throughout
///
/// It is the profile the correctness gate is defined on, and it still exercises
/// every structure the reported profiles do: several categories, the full
/// pricing ladder, a cart with promotions, and both halves of an inventory
/// burst.
///
/// Serialized because each test drives four complete sessions, and a session
/// that is timing out because three others are competing for the MainActor is a
/// failure nobody can read.
@Suite("Cross-runtime Storefront agreement", .serialized)
struct CrossRuntimeAgreementTests {
  /// The slugs of the four runtimes this suite is written for, sorted.
  ///
  /// Pinned so that adding a fifth runtime and not extending this suite fails
  /// here rather than silently comparing the old four.
  static let expectedSlugs = ["cog", "observation-memo", "observation-raw", "state-graph"]

  /// Runs the trace once against each of the four runtimes.
  ///
  /// Sequential rather than concurrent: every runtime is MainActor-confined, so
  /// four concurrent sessions would interleave on one executor and turn a
  /// failure into a puzzle for no wall-clock gain.
  ///
  /// - Returns: One observation per runtime, in the order the runtimes are
  ///   reported in a results table, Cog first, then the floor, then the two
  ///   that do real work to avoid recomputation.
  func observeEveryRuntime() async throws -> [RuntimeAgreementObservation] {
    [
      try await observeAgreementSession(CogStorefrontRuntime.self),
      try await observeAgreementSession(RawObservationStorefrontRuntime.self),
      try await observeAgreementSession(MemoObservationStorefrontRuntime.self),
      try await observeAgreementSession(StateGraphStorefrontRuntime.self),
    ]
  }

  // MARK: - The trace itself

  /// Every runtime completes the whole trace with every checkpoint holding, no
  /// unexplained skip, and nothing left outstanding.
  ///
  /// This runs first because the comparisons that follow are meaningless
  /// otherwise: two runtimes that both failed the same checkpoint would agree
  /// with each other perfectly.
  ///
  /// The skip set is asserted against the runtime's *own declaration* rather
  /// than merely counted. A skip records as holding, so an unexamined skip is
  /// how a claim stops being checked without anyone reading a failure; requiring
  /// the skips to be exactly the ones the declared semantics predict means a
  /// runtime cannot quietly acquire a third one.
  @Test("every runtime completes the eleven-phase trace")
  func everyRuntimeCompletesTheTrace() async throws {
    let observations = try await observeEveryRuntime()
    #expect(observations.map(\.slug).sorted() == Self.expectedSlugs)

    for observation in observations {
      for failure in observation.checkpointFailures {
        Issue.record(
          "\(observation.slug) failed a checkpoint: \(failure.failureDescription)"
        )
      }
      #expect(
        observation.checkpointFailures.isEmpty,
        "\(observation.slug) did not satisfy the trace"
      )
      #expect(
        observation.phaseRenderings.map(\.phase) == StorefrontPhase.allCases,
        "\(observation.slug) did not record all eleven phase boundaries"
      )
      #expect(
        observation.outstandingRequestCount == 0,
        """
        \(observation.slug) ended the session with \
        \(observation.outstandingRequestCount) outstanding request(s); a runtime \
        that had quietly stopped asking for something would end with fewer \
        requests and identical rendered output, so this is the clause that \
        separates the same answer from the same answer for the same reasons.
        """
      )
      #expect(
        observation.skippedCheckpointNames == Self.expectedSkips(for: observation),
        """
        \(observation.slug) skipped \(observation.skippedCheckpointNames), which is \
        not what its declared semantics predict. A skip records as holding, so a \
        skip nobody predicted is a claim that stopped being checked.
        """
      )
    }

    // One script means one set of claims. A runtime that recorded a different
    // number of checkpoints took a branch its siblings did not.
    let counts = Set(observations.map(\.checkpointCount))
    #expect(
      counts.count == 1,
      """
      The four runtimes recorded different numbers of checkpoints: \
      \(observations.map { "\($0.slug)=\($0.checkpointCount)" }.joined(separator: ", ")).
      """
    )
  }

  /// The checkpoints one runtime's declared semantics excuse it from.
  ///
  /// There are exactly two legal skips in the whole trace and they are listed
  /// here in the order the teardown phase records them. A third would fail the
  /// assertion above rather than being absorbed.
  ///
  /// - Parameter observation: The runtime whose declarations decide this.
  /// - Returns: The names the trace should have skipped, in order.
  static func expectedSkips(for observation: RuntimeAgreementObservation) -> [String] {
    var expected: [String] = []
    if !observation.descriptor.semantics.hasPerGenerationRefreshHandles {
      expected.append("superseded refresh")
    }
    if !observation.descriptor.semantics.releasesUnobservedValues {
      expected.append("released row asks again")
    }
    return expected
  }

  // MARK: - Agreement

  /// The four runtimes render the same screen at every branch-free phase
  /// boundary, and each agrees with the shared shadow wherever the shadow is an
  /// oracle.
  ///
  /// Ten of the eleven boundaries are branch-free, every runtime executes
  /// exactly the same steps to reach them, so all four owe identical visible
  /// identifiers and identical digests at each. The eleventh, `teardown`, is
  /// not: its tail is chosen by the runtime's declared lifetime semantics, and
  /// it is handled by ``runtimesAgreeOnTheFinalSettledState()`` below.
  ///
  /// A runtime that diverged in the middle and converged again by the last phase
  /// would pass an end-of-session comparison while having rendered screens
  /// nobody asked for. Comparing after every phase is what closes that gap, and
  /// it is why this suite runs the phases individually rather than calling
  /// ``StorefrontSessionDriver/runStandardTrace()``.
  ///
  /// The first two boundaries are compared against the shadow more narrowly,
  /// because the shadow is not yet an oracle for them and pretending otherwise
  /// would be checking the wrong thing. ``StorefrontWorld`` holds the catalog,
  /// the search index, and every fixture response from the moment it is
  /// constructed, it models the *settled* world, whereas the session has
  /// released nothing at `bootstrap` and only its root responses after
  /// `rootData`. So `bootstrap` is checked for an empty screen, which is the
  /// claim the trace itself makes there, and `rootData` for visible identifiers
  /// only: the digest folds in live inventory and personalized offers whose
  /// requests are still in flight until `initialRowData` drains them. The
  /// *cross-runtime* comparison is exact at all ten regardless, because a
  /// request in flight is in flight for all four.
  @Test("the runtimes agree with each other and the shadow at every phase")
  func runtimesAgreeAtEveryPhaseBoundary() async throws {
    let observations = try await observeEveryRuntime()
    let reference = try #require(observations.first)
    for observation in observations {
      try #require(
        observation.phaseRenderings.map(\.phase) == StorefrontPhase.allCases,
        "\(observation.slug) did not record all eleven phase boundaries, in order"
      )
    }

    for phase in StorefrontPhase.allCases where phase != .teardown {
      let referenceRendering = try #require(reference.rendering(after: phase))
      for candidate in observations.dropFirst() {
        let rendering = try #require(candidate.rendering(after: phase))
        expectSameRendering(
          rendering,
          referenceRendering,
          phase: phase,
          runtime: candidate.slug,
          reference: reference.slug
        )
      }
    }

    for observation in observations {
      for phase in StorefrontPhase.allCases {
        let rendering = try #require(observation.rendering(after: phase))
        expectMatchesShadow(rendering, runtime: observation.slug)
      }
    }
  }

  /// Requires one boundary's rendering to match the shadow as far as the shadow
  /// is an oracle for it.
  ///
  /// - Parameters:
  ///   - rendering: The boundary to check.
  ///   - runtime: The runtime's slug, so a failure names it.
  func expectMatchesShadow(_ rendering: PhaseRendering, runtime: String) {
    switch Self.oracle(for: rendering.phase) {
    case .emptyScreen:
      #expect(
        rendering.visibleProductIDs.isEmpty,
        "\(runtime) rendered rows into the loading shell"
      )
      return
    case .visibleIdentifiersOnly, .full:
      #expect(
        rendering.visibleProductIDs == rendering.shadowVisibleProductIDs,
        """
        After the \(rendering.phase.rawValue) phase \(runtime) showed \
        \(describe(rendering.visibleProductIDs)) where the shadow expected \
        \(describe(rendering.shadowVisibleProductIDs)).
        """
      )
    }
    guard Self.oracle(for: rendering.phase) == .full else { return }
    #expect(
      rendering.visibleChecksum == rendering.shadowVisibleChecksum,
      """
      After the \(rendering.phase.rawValue) phase \(runtime) rendered checksum \
      \(rendering.visibleChecksum) where the shadow expected \
      \(rendering.shadowVisibleChecksum).
      """
    )
    guard !rendering.shadowCartIsEmpty else { return }
    #expect(
      rendering.orderTotal == rendering.shadowOrderTotal,
      """
      After the \(rendering.phase.rawValue) phase \(runtime) totalled \
      \(rendering.orderTotal.totalCents) where the shadow expected \
      \(rendering.shadowOrderTotal.totalCents).
      """
    )
  }

  /// How far the shadow can be trusted at one boundary.
  ///
  /// ``StorefrontWorld`` holds the catalog, the search index, and every fixture
  /// response from the moment it is constructed: it models the *settled* world.
  /// The session does not. So the shadow is not an oracle for everything at
  /// every boundary, and pretending it is would be checking the wrong thing
  /// loudly rather than the right thing quietly.
  enum ShadowOracle {
    /// The shadow says nothing useful yet; only the empty screen is a claim.
    case emptyScreen
    /// The identifiers are settled but the digest is not, because it folds in
    /// live inventory and personalized offers still in flight.
    case visibleIdentifiersOnly
    /// The shadow is a complete oracle.
    case full
  }

  /// The ruling for one phase.
  ///
  /// - Parameter phase: The boundary.
  /// - Returns: How far the shadow can be trusted there.
  static func oracle(for phase: StorefrontPhase) -> ShadowOracle {
    switch phase {
    case .bootstrap: .emptyScreen
    case .rootData: .visibleIdentifiersOnly
    default: .full
    }
  }

  /// The four runtimes settle to the same final answer, and to the same shadow.
  ///
  /// Compares visible IDs, rendered digest, suggestions, order total, and each
  /// runtime's independent shadow from the same profile and events.
  ///
  /// ## Why the last boundary is compared in two pieces
  ///
  /// The `teardown` phase branches on
  /// ``StorefrontRuntimeSemantics/releasesUnobservedValues``. A runtime that
  /// releases values scrolls back to rebuild one and ends with visible rows. A
  /// runtime that caches nothing skips that proof and keeps an empty window.
  /// This script difference makes final IDs incomparable across branches.
  ///
  /// Browse output is compared within each non-empty branch group and against
  /// each runtime's shadow. Suggestions, cart money, and outstanding requests
  /// do not branch, so all four must agree.
  @Test("the runtimes settle to the same final answer")
  func runtimesAgreeOnTheFinalSettledState() async throws {
    let observations = try await observeEveryRuntime()
    let reference = try #require(observations.first)

    // Each runtime against the shadow it derived itself, which is the right
    // oracle for it because it was derived from the same branch.
    for observation in observations {
      #expect(
        observation.visibleProductIDs == observation.shadowVisibleProductIDs,
        """
        \(observation.slug) settled showing \(describe(observation.visibleProductIDs)) \
        where its shadow expected \(describe(observation.shadowVisibleProductIDs)).
        """
      )
      #expect(
        observation.visibleChecksum == observation.shadowVisibleChecksum,
        """
        \(observation.slug) settled to checksum \(observation.visibleChecksum) where \
        its shadow expected \(observation.shadowVisibleChecksum).
        """
      )
      #expect(
        observation.suggestions == observation.shadowSuggestions,
        """
        \(observation.slug) settled to suggestions \(observation.suggestions) where \
        its shadow expected \(observation.shadowSuggestions).
        """
      )
      if !observation.shadowCartIsEmpty {
        #expect(
          observation.orderTotal == observation.shadowOrderTotal,
          """
          \(observation.slug) settled to order total \(observation.orderTotal.totalCents) \
          where its shadow expected \(observation.shadowOrderTotal.totalCents).
          """
        )
      }
    }

    // Suggestions and the cart's money are untouched by the teardown branch, so
    // all four are compared against one another directly.
    for candidate in observations.dropFirst() {
      #expect(
        candidate.suggestions == reference.suggestions,
        """
        \(candidate.slug) settled to suggestions \(candidate.suggestions) where \
        \(reference.slug) settled to \(reference.suggestions).
        """
      )
      #expect(
        candidate.orderTotal == reference.orderTotal,
        """
        \(candidate.slug) settled to order total \(candidate.orderTotal.totalCents) \
        where \(reference.slug) settled to \(reference.orderTotal.totalCents).
        """
      )
    }

    // The browse screen, within each teardown branch. Grouping rather than
    // skipping: every runtime is still compared with every runtime that ran the
    // same steps it did, and the independently derived shadows are compared with
    // it, so a group that agreed with itself while disagreeing with the model
    // still fails.
    for releases in [true, false] {
      let group = observations.filter {
        $0.descriptor.semantics.releasesUnobservedValues == releases
      }
      guard let groupReference = group.first else { continue }
      for candidate in group.dropFirst() {
        #expect(
          candidate.visibleProductIDs == groupReference.visibleProductIDs,
          """
          \(candidate.slug) ended showing \(describe(candidate.visibleProductIDs)) \
          where \(groupReference.slug) ended showing \
          \(describe(groupReference.visibleProductIDs)).
          """
        )
        #expect(
          candidate.visibleChecksum == groupReference.visibleChecksum,
          """
          \(candidate.slug) ended with checksum \(candidate.visibleChecksum) where \
          \(groupReference.slug) ended with \(groupReference.visibleChecksum).
          """
        )
        #expect(
          candidate.shadowVisibleChecksum == groupReference.shadowVisibleChecksum,
          """
          \(candidate.slug) and \(groupReference.slug) ran the same teardown steps \
          but their independently derived shadows disagree, so the two sessions \
          were not the same session.
          """
        )
      }
    }

    // Non-vacuity: the grouping above is only a real comparison if some group
    // holds more than one runtime. Three runtimes declare a lifetime release
    // today, so the releasing group compares three sessions against each other.
    let releasingCount = observations.count {
      $0.descriptor.semantics.releasesUnobservedValues
    }
    #expect(
      releasingCount >= 2,
      """
      Fewer than two runtimes declare a lifetime release, so the final browse \
      screen is no longer compared across runtimes at all.
      """
    )
  }

  // MARK: - Declared semantics

  /// Records what each runtime declared, requires the fields that admit no
  /// variation to be invariant, and reports the ones that legitimately differ.
  ///
  /// ``StorefrontRuntimeSemantics`` allows valid differences. For example, a
  /// runtime that recomputes on each read also renders after an equal write.
  /// ``DeclaredSemanticsField`` says which fields may differ so ports cannot opt
  /// out of the shared contract.
  ///
  /// Differing fields are printed for the results table. Producing the table
  /// from this gate keeps documentation tied to the checked values.
  @Test("the semantics that admit no variation are invariant across runtimes")
  func invariantSemanticsAreInvariant() async throws {
    let descriptors: [StorefrontRuntimeDescriptor] = [
      CogStorefrontRuntime.descriptor,
      RawObservationStorefrontRuntime.descriptor,
      MemoObservationStorefrontRuntime.descriptor,
      StateGraphStorefrontRuntime.descriptor,
    ]
    #expect(descriptors.map(\.slug).sorted() == Self.expectedSlugs)
    #expect(
      Set(descriptors.map(\.displayName)).count == descriptors.count,
      "two runtimes share a display name, so a results table cannot tell them apart"
    )

    var report = ["Declared Storefront runtime semantics, per field:"]
    for field in DeclaredSemanticsField.all {
      let values = descriptors.map { (slug: $0.slug, value: field.value($0.semantics)) }
      let rendered = values.map { "\($0.slug)=\($0.value)" }.joined(separator: ", ")
      if field.admitsVariation {
        report.append("  \(field.name) [varies]: \(rendered)")
      } else {
        report.append("  \(field.name) [invariant]: \(rendered)")
        #expect(
          Set(values.map(\.value)).count == 1,
          """
          \(field.name) admits no variation across runtimes, but the four \
          declared \(rendered).

          \(field.rationale)
          """
        )
      }
    }
    print(report.joined(separator: "\n"))
  }

  /// ``DeclaredSemanticsField/all`` names every field of
  /// ``StorefrontRuntimeSemantics``, and reads each one correctly.
  ///
  /// Reflection rather than a hand-maintained count. A field added to the struct
  /// and not to the table would otherwise be a field nobody ruled on, silently
  /// neither asserted nor reported, and an accessor that read the neighbouring
  /// field would be invisible, which is the copy-paste mistake a table of eight
  /// near-identical closures invites.
  @Test("the semantics table covers every declared field")
  func semanticsTableCoversEveryField() {
    let semantics = RawObservationStorefrontRuntime.descriptor.semantics
    let children = Mirror(reflecting: semantics).children
    let labels = children.compactMap(\.label)
    #expect(
      labels.count == children.count,
      "StorefrontRuntimeSemantics has an unlabelled stored property"
    )
    #expect(
      labels == DeclaredSemanticsField.all.map(\.name),
      """
      DeclaredSemanticsField.all does not match StorefrontRuntimeSemantics: the \
      struct declares \(labels) and the table names \
      \(DeclaredSemanticsField.all.map(\.name)).
      """
    )
    for (child, field) in zip(children, DeclaredSemanticsField.all) {
      #expect(
        String(describing: child.value) == field.value(semantics),
        """
        The table's accessor for \(field.name) rendered \(field.value(semantics)) \
        where the field itself holds \(String(describing: child.value)), so the \
        table is reading the wrong property.
        """
      )
    }
  }

  // MARK: - Comparison helpers

  /// Requires two runtimes to have rendered the same screen at one boundary.
  ///
  /// - Parameters:
  ///   - rendering: What the candidate runtime rendered.
  ///   - reference: What the reference runtime rendered.
  ///   - phase: Which boundary, so a failure names it.
  ///   - runtime: The candidate's slug.
  ///   - reference: The reference's slug.
  func expectSameRendering(
    _ rendering: PhaseRendering,
    _ referenceRendering: PhaseRendering,
    phase: StorefrontPhase,
    runtime: String,
    reference: String
  ) {
    #expect(
      rendering.visibleProductIDs == referenceRendering.visibleProductIDs,
      """
      After the \(phase.rawValue) phase \(runtime) showed \
      \(describe(rendering.visibleProductIDs)) where \(reference) showed \
      \(describe(referenceRendering.visibleProductIDs)).
      """
    )
    #expect(
      rendering.visibleChecksum == referenceRendering.visibleChecksum,
      """
      After the \(phase.rawValue) phase \(runtime) rendered checksum \
      \(rendering.visibleChecksum) where \(reference) rendered \
      \(referenceRendering.visibleChecksum).
      """
    )
    // Compare money only for non-empty carts, as `requireSettledOutput` does.
    // An empty cart has no shipping or tax quote to compare with the shadow.
    guard !rendering.shadowCartIsEmpty, !referenceRendering.shadowCartIsEmpty else { return }
    #expect(
      rendering.orderTotal == referenceRendering.orderTotal,
      """
      After the \(phase.rawValue) phase \(runtime) totalled \
      \(rendering.orderTotal.totalCents) where \(reference) totalled \
      \(referenceRendering.orderTotal.totalCents).
      """
    )
  }

  /// Renders product identifiers for a failure message.
  ///
  /// - Parameter ids: The identifiers, in list order.
  /// - Returns: A bracketed, comma-separated list.
  func describe(_ ids: [ProductID]) -> String {
    "[\(ids.map(\.description).joined(separator: ", "))]"
  }
}
