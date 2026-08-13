extension Cogtext {
  /// Reads a source and registers its exact state with the active UI consumer.
  ///
  /// Use this from a SwiftUI view body. For a peek that should not
  /// invalidate the view, use ``peek(_:)``.
  public subscript<Value>(_ valueReference: ManualCog<Value>) -> Value {
    let state = manualState(for: valueReference)
    state.accessObservationBoundary(in: self)
    return state.currentValue
  }

  /// Reads a derived cog and registers its exact state with the active UI
  /// consumer.
  ///
  /// The read settles the value before returning it. Later turns invalidate
  /// the consumer only when the settled value changes.
  public subscript<Value>(_ valueReference: Cog<Value>) -> Value {
    let state = derivedState(for: valueReference)
    state.accessObservationBoundary(in: self)
    return state.settledValue(in: self)
  }

  /// Reads an async cog's full phase through the Observation boundary.
  ///
  /// The read first settles the exact descriptor-and-key state. A first read
  /// therefore selects work and publishes pending before returning; a dirty
  /// state selects replacement work before its current phase is observed. Only
  /// after settlement does Cog register the Observation access, so the boundary
  /// tracks the phase returned by this call rather than receiving a redundant
  /// notice for the initial pending publication.
  ///
  /// This is UI tracking, not a selector or reaction dependency edge. Creating
  /// the boundary pins the state against `whileObserved` release, and later
  /// pending, success, or failure turns notify the active Observation consumer.
  /// Use ``peek(_:)`` for a one-shot read that should not invalidate UI and does
  /// not keep the async state durably observed.
  ///
  /// - Parameter valueReference: The async value whose phase the UI reads.
  /// - Returns: The newest settled phase in this context.
  public subscript<Value>(_ valueReference: AsyncCog<Value>) -> CogPhase<Value> {
    let state = asyncState(for: valueReference)
    let phase = state.settledPhase(in: self)
    state.accessObservationBoundary(in: self)
    return phase
  }

  /// Reads a source's read-only projection through the UI boundary.
  public subscript<Value>(_ valueReference: CogProjection<Value>) -> Value {
    self[valueReference.source]
  }
}
