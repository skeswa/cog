/// Which value-reference layout a scenario builds its keyed references with.
///
/// The keyed shapes — diamonds over a box, key churn — are the ones whose cost
/// depends on how a `box[key]` reference is physically represented (perf §4).
/// Every scenario therefore carries the layout it was built for, so the same
/// graph can be built again under a different candidate without editing the
/// scenario, and so a recorded measurement can never be read without knowing
/// which representation produced it.
///
/// Only the baseline exists today. `M5-09b` and `M5-09c` add the interned-token
/// and generic-keyed candidates, and `M5-09a` puts the selection behind
/// `COG_TEST_VALUE_REFERENCE_LAYOUT`; adding a case here is the whole change a
/// scenario needs, because run counts are a property of the graph rather than
/// of the representation.
public enum CogValueReferenceLayout: String, Sendable, CaseIterable {
  /// Inline `AnyHashable` keys: the correctness core's representation.
  ///
  /// Named as a candidate rather than assumed, because the layout stays open
  /// until benchmarks choose it (perf §9, §10).
  case inline
}
