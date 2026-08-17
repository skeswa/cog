/// Which value-reference layout a scenario builds its keyed references with.
///
/// The keyed shapes — diamonds over a box, key churn — are the ones whose cost
/// depends on how a `box[key]` reference is physically represented (perf §4).
/// Every scenario therefore carries the layout it was built for, so the same
/// graph can be built again under a different candidate without editing the
/// scenario, and so a recorded measurement can never be read without knowing
/// which representation produced it.
///
/// The root package chooses one case at build time through
/// `COG_TEST_VALUE_REFERENCE_LAYOUT`. Scenarios record that compiled case as
/// metadata; run counts remain a property of the graph rather than of the
/// representation.
public enum CogValueReferenceLayout: String, Sendable, CaseIterable {
  /// Inline `AnyHashable` keys: the selected v1 representation.
  case inline

  /// Process-wide interned key tokens carried by erased value references.
  case interned

  /// Box-produced value references that retain their concrete key type.
  case generic

  /// The layout the root Cog package and these shared scenarios compiled with.
  ///
  /// Keeping this decision in the compiled target prevents a benchmark from
  /// labeling a generic build as inline merely because the scenario factory
  /// predates the build selector.
  public static var compiled: CogValueReferenceLayout {
    #if COG_VALUE_REFERENCE_LAYOUT_INLINE
    .inline
    #elseif COG_VALUE_REFERENCE_LAYOUT_INTERNED
    .interned
    #elseif COG_VALUE_REFERENCE_LAYOUT_GENERIC
    .generic
    #else
    #error("Package.swift defined no value-reference layout for CogScenarios")
    #endif
  }
}
