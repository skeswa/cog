/// Swift Observation-tracked UI reads on a context.
///
/// These subscripts are MainActor-isolated with ``Cogs``. Each one settles
/// before returning and records the exact state with the caller's active
/// Observation tracking scope; use ``Cogs/peek(_:)`` for a current read that
/// should not invalidate UI later.
extension Cogs {
  /// Reads a source and registers its exact state with the active UI consumer.
  ///
  /// Use this from a SwiftUI view body. Later changed turns notify the active
  /// Observation consumer after the turn has finished; reading does not create
  /// a selector or reaction dependency edge.
  ///
  /// - Parameter valueReference: The source identity to observe.
  /// - Returns: Its value from the latest completed turn.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  public subscript<Value>(_ valueReference: Cog<Value>.Manual) -> Value {
    return arenaCore.observedManualValue(for: valueReference)
  }

  /// Reads an automatic cog and registers its exact state with the active UI
  /// consumer.
  ///
  /// The read settles the value before returning it. Later turns invalidate
  /// the consumer only when the settled value changes. Settlement happens
  /// before boundary access, so cold async-backed automatic state can establish
  /// pending without reentering this read or sending a redundant baseline
  /// notice. The boundary pins this exact automatic state for the context lifetime
  /// in v1.
  ///
  /// - Parameter valueReference: The automatic identity to settle and observe.
  /// - Returns: Its newest fully settled value.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  public subscript<Value>(_ valueReference: Cog<Value>) -> Value {
    return arenaCore.observedAutomaticValue(for: valueReference, in: self)
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
  /// reload succeeds with an equal value; read ``Cogs/status`` where the
  /// request lifecycle itself drives chrome.
  ///
  /// This is UI tracking, not a selector or reaction dependency edge. Creating
  /// the boundary pins the projection — and, through its dependency, the async
  /// state — against `whileObserved` release. Use ``peek(_:)-(Cog<Value>.Async)`` for a one-shot
  /// read that should not invalidate UI and does not keep the async state
  /// durably observed.
  ///
  /// - Parameter valueReference: The async value the UI reads.
  /// - Returns: Its newest settled value in this context.
  public subscript<Value>(_ valueReference: Cog<Value>.Async) -> Value {
    self[valueReference.valueCog]
  }

  /// Reads a source's read-only projection through the UI boundary.
  ///
  /// The projection and writable source share one identity and one Observation
  /// boundary; this overload exposes no write capability.
  ///
  /// - Parameter valueReference: The read-only source projection to observe.
  /// - Returns: Its source value from the latest completed turn.
  public subscript<Value>(_ valueReference: Cog<Value>.Projection) -> Value {
    self[valueReference.sourceCog]
  }
}
