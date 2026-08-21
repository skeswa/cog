public import Cog

// MARK: - Observation-boundary inspection

extension Cogs {
  /// How many exact states a UI read has pinned with an Observation boundary.
  ///
  /// This is the narrow seam behind "only cogs a view actually read get a
  /// boundary object" (UI-05): a count, never the states or the boundary
  /// objects themselves, so a behavior test stays valid across state-storage
  /// and core swaps.
  public var observationBoundaryCount: Int {
    observationBoundaryCountForTesting
  }

  /// Whether this source's exact state currently owns an Observation boundary.
  ///
  /// Purely a lookup: probing a state never demanded in this context reports
  /// `false` without creating it, so a test can ask about interior or unread
  /// states without disturbing laziness or lifetime.
  public func hasObservationBoundary<Value>(for valueReference: ManualCog<Value>) -> Bool {
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
