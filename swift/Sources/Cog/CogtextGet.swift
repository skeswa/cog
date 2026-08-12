extension Cogtext {
  /// Reads a source and registers its exact state with the active UI consumer.
  ///
  /// Use this from a SwiftUI view body. For a one-shot read that should not
  /// invalidate the view, use ``read(_:)``.
  public func get<Value>(_ valueReference: ManualCog<Value>) -> Value {
    let state = manualState(for: valueReference)
    state.accessObservationBoundary()
    return state.currentValue
  }

  /// Reads a derived cog and registers its exact state with the active UI
  /// consumer.
  ///
  /// The read settles the value before returning it. Later turns invalidate
  /// the consumer only when the settled value changes.
  public func get<Value>(_ valueReference: Cog<Value>) -> Value {
    let state = derivedState(for: valueReference)
    state.accessObservationBoundary()
    return state.settledValue(in: self)
  }

  /// Reads a source's read-only projection through the UI boundary.
  public func get<Value>(_ valueReference: CogProjection<Value>) -> Value {
    get(valueReference.source)
  }
}
