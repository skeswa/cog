public import Cog

// MARK: - Observation-boundary inspection

extension Cogs {
  /// How many exact states a UI read has pinned with an Observation boundary.
  ///
  /// UI-05 uses this count to prove that only view reads create boundaries. It
  /// exposes no states or boundary objects, so the test does not depend on the
  /// storage design.
  public var observationBoundaryCount: Int {
    observationBoundaryCountForTesting
  }

  /// Whether this source's exact state currently owns an Observation boundary.
  ///
  /// Purely a lookup: probing a state never demanded in this context reports
  /// `false` without creating it, so a test can ask about interior or unread
  /// states without disturbing laziness or lifetime.
  public func hasObservationBoundary<Value>(for valueReference: Cog<Value>.Manual) -> Bool {
    hasObservationBoundaryForTesting(for: valueReference)
  }

  /// Whether this automatic cog's exact state currently owns an Observation
  /// boundary.
  ///
  /// Purely a lookup: probing a state never demanded in this context reports
  /// `false` without creating it, so a test can ask about interior or unread
  /// states without disturbing laziness or lifetime.
  public func hasObservationBoundary<Value>(for valueReference: Cog<Value>) -> Bool {
    hasObservationBoundaryForTesting(for: valueReference)
  }
}
