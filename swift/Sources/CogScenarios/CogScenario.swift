public import Cog

/// One benchmark graph shape, the turns driven through it, and the number of
/// selector runs it should cost.
///
/// The ported `js-reactivity-benchmark` cases (perf §9.2) are values of this
/// type, shared by `CogScenarioTests` and — later — the separate benchmark
/// package. Sharing them is the point: a run-count assertion and a timing
/// measurement that disagree about which graph they ran would make both
/// meaningless.
///
/// A scenario owns its whole story. `run(in:)` builds the declarations, reads
/// them, commits turns, and reports what happened, so nothing about the shape
/// leaks into the caller and a test cannot accidentally change the workload it
/// is asserting on.
@MainActor
public struct CogScenario {
  /// What this scenario is called in results and test names.
  public let name: String

  /// The value-reference layout its keyed declarations were built with.
  public let layout: CogValueReferenceLayout

  /// How many selector runs the shape costs, derived from its parameters.
  ///
  /// Derived, never a recorded observation: an expected count computed from
  /// the graph's own size and turn count is a claim about how Cog *should*
  /// behave, whereas a count copied from a passing run only says what it did
  /// once. Duplicate work has to fail this comparison to be worth running.
  public let expectedRuns: Int

  /// Builds the graph, drives its turns, increments `counter` inside its own
  /// selectors, and returns the value it finished on.
  private let body: @MainActor (Cogs, CogRunCounter) -> Int

  /// Creates a scenario from its shape and its derived expectation.
  ///
  /// - Parameters:
  ///   - name: Identifier used in results and in the test that asserts on it.
  ///   - layout: The value-reference layout `body` builds keyed references
  ///     with. Keyless shapes still record it, so a result set is uniform.
  ///   - expectedRuns: Selector runs the shape must cost, computed from the
  ///     caller's parameters rather than measured.
  ///   - body: Builds declarations, reads them, and commits turns. It receives
  ///     the context to run in and the counter its selectors increment, and
  ///     returns the value its root cog finished on.
  public init(
    name: String,
    layout: CogValueReferenceLayout,
    expectedRuns: Int,
    body: @escaping @MainActor (Cogs, CogRunCounter) -> Int
  ) {
    self.name = name
    self.layout = layout
    self.expectedRuns = expectedRuns
    self.body = body
  }

  /// Runs the whole scenario once in `cogs` and reports actual against
  /// expected.
  ///
  /// Each call uses a fresh counter, so a scenario may be run repeatedly — in
  /// a benchmark loop, or once per value-reference layout — without earlier
  /// runs contaminating the count. Give each call its own isolated context:
  /// declarations create their state lazily per context, so a reused context
  /// would start warm and undercount.
  ///
  /// - Parameter cogs: The isolated context to build this graph in.
  /// - Returns: The name, layout, and the two counts to compare.
  public func run(in cogs: Cogs) -> CogScenarioResult {
    let counter = CogRunCounter()
    let finalValue = body(cogs, counter)
    return CogScenarioResult(
      name: name,
      layout: layout,
      actualRuns: counter.runs,
      expectedRuns: expectedRuns,
      finalValue: finalValue
    )
  }
}

/// What one scenario run cost, against what it should have cost.
///
/// `nonisolated` so a test or benchmark can carry the result out of the
/// MainActor run and report it wherever it reports results.
public nonisolated struct CogScenarioResult: Sendable, Equatable {
  /// The scenario that produced this result.
  public let name: String

  /// The value-reference layout it was built with.
  public let layout: CogValueReferenceLayout

  /// Selector runs that actually happened.
  public let actualRuns: Int

  /// Selector runs the shape should have cost.
  public let expectedRuns: Int

  /// The value the scenario's root cog held when the run finished.
  ///
  /// Counting runs alone would pass a graph that ran the right number of times
  /// and computed the wrong answer, so every ported case also carries the
  /// arithmetic its upstream original asserts on.
  public let finalValue: Int

  /// Whether Cog did exactly the work the shape requires — no more, no less.
  ///
  /// Exact equality in both directions on purpose. Too many runs is duplicate
  /// work, which is the whole point of counting; too few means the scenario
  /// did not drive the graph it claims to, so its number would be a
  /// comfortable lie.
  public var isExact: Bool { actualRuns == expectedRuns }

  /// Creates a result. Scenarios produce these; callers compare them.
  public init(
    name: String,
    layout: CogValueReferenceLayout,
    actualRuns: Int,
    expectedRuns: Int,
    finalValue: Int
  ) {
    self.name = name
    self.layout = layout
    self.actualRuns = actualRuns
    self.expectedRuns = expectedRuns
    self.finalValue = finalValue
  }
}
