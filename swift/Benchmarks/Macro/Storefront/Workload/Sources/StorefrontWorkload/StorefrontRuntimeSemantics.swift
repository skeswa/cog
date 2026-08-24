/// What a runtime is called, and what it structurally guarantees.
///
/// A value type with no identity of its own: it is read out of
/// ``StorefrontRuntime/descriptor``, copied into the driver once, and never
/// mutated. `nonisolated` and `Sendable` because a benchmark registration and a
/// results table both name it from outside the MainActor.
public nonisolated struct StorefrontRuntimeDescriptor: Sendable, Hashable {
  /// The runtime's benchmark-name slug: `cog`, `observation-raw`,
  /// `observation-memo`, `state-graph`.
  ///
  /// This is the string that appears in `perf-16-storefront-<slug>-<cut>`, so
  /// it is the runtime's identity in every recorded number.
  public let slug: String

  /// The runtime's name in a results table, such as "raw `@Observable`".
  public let displayName: String

  /// What this runtime structurally guarantees.
  public let semantics: StorefrontRuntimeSemantics

  /// Names one runtime and records what it guarantees.
  ///
  /// - Parameters:
  ///   - slug: The benchmark-name slug. Stable for the life of the runtime,
  ///     because a recorded number is only comparable to another number
  ///     recorded under the same slug.
  ///   - displayName: How the runtime is spelled in prose and in a table.
  ///   - semantics: The structural guarantees the trace holds this runtime to.
  public init(slug: String, displayName: String, semantics: StorefrontRuntimeSemantics) {
    self.slug = slug
    self.displayName = displayName
    self.semantics = semantics
  }
}

/// What a runtime structurally guarantees, so a run-count checkpoint can state
/// the right expectation for it.
///
/// Nine of the forty-one checkpoints a smoke run records assert an exact
/// number of held-observer runs, and two more assert how many requests an
/// offscreen half started. Those numbers are claims about *invalidation*, and a
/// runtime that recomputes on every read cannot produce Cog's numbers and is
/// not wrong for failing to — it is the floor being measured. Rather than
/// deleting the sharpest claims in the trace, each runtime declares what its
/// numbers should be and the trace asserts against the declaration. Declaring
/// a convenient lie does not help: the identity, checksum, money, and promotion
/// checkpoints admit no per-runtime variation, and neither does
/// ``StorefrontSessionDriver/requireSettledOutput(against:)``.
///
/// Every value here must be justified in the port's own `README.md` section
/// and repeated in `docs/swift/impl/perf.md`. An undocumented value is a
/// review failure.
public nonisolated struct StorefrontRuntimeSemantics: Sendable, Hashable {
  /// How many browse-observer runs one settled transaction that changes
  /// visible content produces. One for a runtime that coalesces a transaction
  /// into a single settlement.
  public let browseRunsPerContentChangingTurn: Int

  /// How many browse-observer runs a write of a value equal to the current one
  /// produces. Zero for a runtime with an equality gate on its sources.
  public let browseRunsPerEqualWrite: Int

  /// How many browse-observer runs a transaction that only invalidates
  /// *offscreen* inputs produces. Zero for a runtime with fine-grained,
  /// demand-driven invalidation.
  public let browseRunsPerUndemandedInvalidation: Int

  /// How many account-observer runs the initial registration and the accepted
  /// account response produce together. Two for a runtime whose account
  /// observer runs once at registration against the resting signed-out value
  /// and once more when the response lands.
  public let accountRunsThroughSignIn: Int

  /// How many service requests this runtime starts when a transaction
  /// invalidates only *offscreen* inputs — the burst phase's central claim, and
  /// the sharpest claim this whole macrobenchmark makes.
  ///
  /// A declared number rather than a yes-or-no, because a yes-or-no lets a port
  /// decline the claim: a runtime that answered "no" would have the checkpoint
  /// skipped, a skip records as holding, and the sharpest measurement in the
  /// workload would evaporate without anyone reading a failure. So every
  /// runtime is held to a stated figure and none may opt out. A runtime with
  /// fine-grained, demand-driven invalidation declares `0`. A runtime that does
  /// start offscreen work declares how much, that number is asserted exactly
  /// like every other, and it lands in the results table as a legible figure
  /// beside Cog's zero rather than as an absence a reader would mistake for a
  /// pass.
  public let declaredUndemandedRequestStarts: Int

  /// Whether a value that survives past grace with no observer is released, so
  /// that re-demanding it asks the service again. A port declaring `false`
  /// causes the teardown phase to skip its release proof and record that it
  /// did, rather than passing it for the wrong reason.
  public let releasesUnobservedValues: Bool

  /// Whether a completed-but-superseded asynchronous result is refused by
  /// generation rather than by relying on task cancellation.
  ///
  /// There is no honest `false` here: ``StorefrontScript`` leaves cancelled
  /// requests suspended by default, so a port that relied on cancellation
  /// would simply fail the stale-result checkpoint. The field exists so the
  /// claim is stated rather than assumed.
  public let refusesStaleResultsByGeneration: Bool

  /// Whether the runtime hands back a per-generation demand handle whose
  /// outcome resolves on replacement.
  public let hasPerGenerationRefreshHandles: Bool

  /// Declares one runtime's structural guarantees.
  ///
  /// Every parameter is a claim the trace will hold the runtime to, so a port
  /// states them once, here, rather than scattering per-runtime conditionals
  /// through the trace's forty-one checkpoints.
  ///
  /// - Parameters:
  ///   - browseRunsPerContentChangingTurn: Browse-observer runs per settled
  ///     transaction that changes visible content.
  ///   - browseRunsPerEqualWrite: Browse-observer runs per write of an
  ///     already-current value.
  ///   - browseRunsPerUndemandedInvalidation: Browse-observer runs per
  ///     transaction that touches only offscreen inputs.
  ///   - accountRunsThroughSignIn: Account-observer runs from registration
  ///     through the accepted account response.
  ///   - declaredUndemandedRequestStarts: How many service requests an
  ///     offscreen-only invalidation starts. Asserted exactly, never skipped.
  ///   - releasesUnobservedValues: Whether an unobserved value is released
  ///     after grace.
  ///   - refusesStaleResultsByGeneration: Whether stale results are refused by
  ///     generation rather than by cancellation.
  ///   - hasPerGenerationRefreshHandles: Whether a demand hands back a handle
  ///     bound to that exact generation.
  public init(
    browseRunsPerContentChangingTurn: Int,
    browseRunsPerEqualWrite: Int,
    browseRunsPerUndemandedInvalidation: Int,
    accountRunsThroughSignIn: Int,
    declaredUndemandedRequestStarts: Int,
    releasesUnobservedValues: Bool,
    refusesStaleResultsByGeneration: Bool,
    hasPerGenerationRefreshHandles: Bool
  ) {
    self.browseRunsPerContentChangingTurn = browseRunsPerContentChangingTurn
    self.browseRunsPerEqualWrite = browseRunsPerEqualWrite
    self.browseRunsPerUndemandedInvalidation = browseRunsPerUndemandedInvalidation
    self.accountRunsThroughSignIn = accountRunsThroughSignIn
    self.declaredUndemandedRequestStarts = declaredUndemandedRequestStarts
    self.releasesUnobservedValues = releasesUnobservedValues
    self.refusesStaleResultsByGeneration = refusesStaleResultsByGeneration
    self.hasPerGenerationRefreshHandles = hasPerGenerationRefreshHandles
  }
}
