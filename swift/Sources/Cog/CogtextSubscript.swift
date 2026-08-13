/// Adds Swift Observation-tracked UI reads to a context.
///
/// These subscripts are MainActor-isolated with ``Cogtext``. Each one settles
/// before returning and records the exact state with the caller's active
/// Observation tracking scope; use ``Cogtext/peek(_:)`` for a current read that
/// should not invalidate UI later.
extension Cogtext {
  /// Reads a source and registers its exact state with the active UI consumer.
  ///
  /// Use this from a SwiftUI view body. Later changed turns notify the active
  /// Observation consumer after the turn has finished; reading does not create
  /// a selector or reaction dependency edge.
  ///
  /// - Parameter valueReference: The source identity to observe.
  /// - Returns: Its value from the latest completed turn.
  public subscript<Value>(_ valueReference: ManualCog<Value>) -> Value {
    let state = manualState(for: valueReference)
    state.accessObservationBoundary(in: self)
    return state.currentValue
  }

  /// Reads a derived cog and registers its exact state with the active UI
  /// consumer.
  ///
  /// The read settles the value before returning it. Later turns invalidate
  /// the consumer only when the settled value changes. Settlement happens
  /// before boundary access, so a cold async-backed derivation can establish
  /// pending without reentering this read or sending a redundant baseline
  /// notice. The boundary pins this exact derived state for the context lifetime
  /// in v1.
  ///
  /// - Parameter valueReference: The derived identity to settle and observe.
  /// - Returns: Its newest fully settled value.
  public subscript<Value>(_ valueReference: Cog<Value>) -> Value {
    let state = derivedState(for: valueReference)
    let value = state.settledValue(in: self)
    state.accessObservationBoundary(in: self)
    return value
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
  ///
  /// The projection and writable source share one identity and one Observation
  /// boundary; this overload exposes no write capability.
  ///
  /// - Parameter valueReference: The read-only source projection to observe.
  /// - Returns: Its source value from the latest completed turn.
  public subscript<Value>(_ valueReference: CogProjection<Value>) -> Value {
    self[valueReference.source]
  }
}
