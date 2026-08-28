import StorefrontWorkload

/// One field of ``StorefrontRuntimeSemantics``, together with the ruling on
/// whether four runtimes may answer it differently.
///
/// ``StorefrontRuntimeSemantics`` exists so that a run-count checkpoint can
/// state the right expectation for the runtime it is asserting against. That is
/// a licence to differ, and most of these fields hold one: a runtime that
/// recomputes on every read genuinely does render on an equal write, and is the
/// floor being measured rather than a defect. But a licence that covered every
/// field would let a port declare its way out of the workload's contract, so
/// this table records, per field, which of the two it is and why, and the
/// suite asserts the ones that admit no variation instead of merely printing
/// them.
///
/// The rulings are read out of the protocol's own documentation rather than
/// invented here; each ``rationale`` names the clause it comes from. Widening
/// ``admitsVariation`` is therefore a change to what the workload requires of a
/// runtime, not a change to a test.
///
/// A value type with `@Sendable` accessors so the whole table can be a
/// `static let` read from any isolation.
struct DeclaredSemanticsField: Sendable {
  /// The field's name, spelled exactly as the Swift property is.
  let name: String

  /// Whether four runtimes may legitimately declare different values.
  let admitsVariation: Bool

  /// Why, in one sentence, pointing at the clause that decides it.
  let rationale: String

  /// Reads this field out of one runtime's declaration, rendered for display.
  ///
  /// A `String` because the fields are a mix of `Int` and `Bool` and the suite
  /// compares and prints them uniformly; a comparison of rendered values is
  /// exactly as strong here, since each rendering is injective.
  let value: @Sendable (StorefrontRuntimeSemantics) -> String

  /// Every field of ``StorefrontRuntimeSemantics``, in declaration order.
  ///
  /// The suite reflects a real ``StorefrontRuntimeSemantics`` value. It checks
  /// these names, their order, and every rendered value. A missing field or an
  /// accessor that reads its neighbor fails.
  static let all: [DeclaredSemanticsField] = [
    DeclaredSemanticsField(
      name: "browseRunsPerContentChangingTurn",
      admitsVariation: false,
      rationale: """
        One settled transaction renders once, for every runtime. \
        `StorefrontRuntime.applyBrowseFilters(category:sortMode:inStockOnly:)` \
        states it as a requirement — separate writes "would render two or three \
        screens no shopper asked for" — and a port whose transaction close \
        rendered more than once would be running a different script, not a \
        slower one.
        """,
      value: { "\($0.browseRunsPerContentChangingTurn)" }
    ),
    DeclaredSemanticsField(
      name: "browseRunsPerEqualWrite",
      admitsVariation: true,
      rationale: """
        An equality gate on sources is a design choice, and its absence is one \
        of the things this comparison exists to price.
        """,
      value: { "\($0.browseRunsPerEqualWrite)" }
    ),
    DeclaredSemanticsField(
      name: "browseRunsPerUndemandedInvalidation",
      admitsVariation: true,
      rationale: """
        Fine-grained, demand-driven invalidation is a design choice; a runtime \
        that re-renders when only offscreen inputs moved is the floor being \
        measured.
        """,
      value: { "\($0.browseRunsPerUndemandedInvalidation)" }
    ),
    DeclaredSemanticsField(
      name: "accountRunsThroughSignIn",
      admitsVariation: true,
      rationale: """
        The trace says so in as many words: "a runtime whose observers register \
        differently owes a different number here and is not wrong for it".
        """,
      value: { "\($0.accountRunsThroughSignIn)" }
    ),
    DeclaredSemanticsField(
      name: "declaredUndemandedRequestStarts",
      admitsVariation: true,
      rationale: """
        Declared as a figure precisely so a runtime that does start offscreen \
        work can state how much and have it asserted, rather than opting out of \
        the sharpest claim in the workload.
        """,
      value: { "\($0.declaredUndemandedRequestStarts)" }
    ),
    DeclaredSemanticsField(
      name: "releasesUnobservedValues",
      admitsVariation: true,
      rationale: """
        A lifetime model is a design choice, and a runtime that caches nothing \
        has nothing to release; the teardown phase skips its release proof and \
        records the skip.
        """,
      value: { "\($0.releasesUnobservedValues)" }
    ),
    DeclaredSemanticsField(
      name: "refusesStaleResultsByGeneration",
      admitsVariation: false,
      rationale: """
        `StorefrontRuntimeSemantics` states that there is no honest `false` \
        here: `StorefrontScript` leaves cancelled requests suspended, so a port \
        relying on cancellation would fail the stale-result checkpoint outright.
        """,
      value: { "\($0.refusesStaleResultsByGeneration)" }
    ),
    DeclaredSemanticsField(
      name: "hasPerGenerationRefreshHandles",
      admitsVariation: true,
      rationale: """
        A per-generation demand handle is a feature a runtime may not have; the \
        teardown phase skips its replacement checkpoint rather than greening it \
        vacuously.
        """,
      value: { "\($0.hasPerGenerationRefreshHandles)" }
    ),
  ]
}
