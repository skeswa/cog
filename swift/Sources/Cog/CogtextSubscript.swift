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

  /// Reads an async cog's value through the Observation boundary.
  ///
  /// This is a total read: it returns the last accepted success, or the
  /// declaration's resting default before one exists. The read resolves
  /// through the async cog's internal value projection, so a first read
  /// creates the async state, starts its work, and returns the default while
  /// that work runs; settlement happens before boundary access, so the cold
  /// pending publication cannot reenter this read or send a redundant
  /// baseline notice. Equality gating keeps the UI consumer quiet when a
  /// reload succeeds with an equal value; read ``Cogtext/phase`` where the
  /// request lifecycle itself drives chrome.
  ///
  /// This is UI tracking, not a selector or reaction dependency edge. Creating
  /// the boundary pins the projection — and, through its dependency, the async
  /// state — against `whileObserved` release. Use ``peek(_:)`` for a one-shot
  /// read that should not invalidate UI and does not keep the async state
  /// durably observed.
  ///
  /// - Parameter valueReference: The async value the UI reads.
  /// - Returns: Its newest settled value in this context.
  public subscript<Value>(_ valueReference: AsyncCog<Value>) -> Value {
    self[valueReference.valueCog]
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
