public import Cog

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

  /// Whether this derived cog's exact state currently owns an Observation
  /// boundary.
  ///
  /// Purely a lookup: probing a state never demanded in this context reports
  /// `false` without creating it, so a test can ask about interior or unread
  /// states without disturbing laziness or lifetime.
  public func hasObservationBoundary<Value>(for valueReference: Cog<Value>) -> Bool {
    hasObservationBoundaryForTesting(for: valueReference)
  }

  #if COG_VALUE_REFERENCE_LAYOUT_GENERIC
  /// Whether a generic candidate's keyed manual source owns a UI boundary.
  public func hasObservationBoundary<Value, Key: Hashable>(
    for valueReference: ManualCogBox<Value, Key>.ValueReference
  ) -> Bool {
    hasObservationBoundaryForTesting(for: valueReference)
  }

  /// Whether a generic candidate's keyed derived value owns a UI boundary.
  public func hasObservationBoundary<Value, Key: Hashable>(
    for valueReference: CogBox<Value, Key>.ValueReference
  ) -> Bool {
    hasObservationBoundaryForTesting(for: valueReference)
  }
  #endif
}
