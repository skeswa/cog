/// The phase lens over a context: the UI-boundary and one-shot read
/// capability for async request lifecycles.
///
/// `cogs.phase[valueReference]` is the opt-in spelling for the full
/// ``CogPhase`` — pending, success, and failure, each its own turn — beside
/// the total value read `cogs[valueReference]`. The lens carries the same
/// read family as the value spelling: a tracked subscript, a non-tracking
/// `peek`, and (in `CogtextWatch`) a `watch`, with identical demand,
/// tracking, and lifetime rules. It deliberately has no spelling for manual
/// or derived cogs: synchronous state has no phase, so asking for one is a
/// type error rather than a degenerate success.
extension Cogtext {
  /// The phase lens for UI-boundary and one-shot phase reads.
  ///
  /// Accessing the property is inert; only the lens's reads touch the graph.
  public var phase: Phase {
    Phase(cogs: self)
  }

  /// The phase-reading facet of one context.
  ///
  /// A lens is a transient borrow of its context's read capability — it holds
  /// no state of its own and creates none until one of its reads demands an
  /// async value.
  @MainActor
  public struct Phase {
    /// The context whose async states this lens reads.
    internal let cogs: Cogtext

    /// Reads an async cog's full phase through the Observation boundary.
    ///
    /// The read first settles the exact descriptor-and-key state. A first
    /// read therefore selects work and publishes pending before returning; a
    /// dirty state selects replacement work before its current phase is
    /// observed. Only after settlement does Cog register the Observation
    /// access, so the boundary tracks the phase returned by this call rather
    /// than receiving a redundant notice for the initial pending publication.
    ///
    /// This is UI tracking, not a selector or reaction dependency edge.
    /// Creating the boundary pins the state against `whileObserved` release,
    /// and later pending, success, or failure turns notify the active
    /// Observation consumer — including a reload that succeeds with an equal
    /// value, which the value read beside this lens would gate away.
    ///
    /// - Parameter valueReference: The async value whose phase the UI reads.
    /// - Returns: The newest settled phase in this context.
    public subscript<Value>(_ valueReference: AsyncCog<Value>) -> CogPhase<Value> {
      let state = cogs.asyncState(for: valueReference)
      let phase = state.settledPhase(in: cogs)
      state.accessObservationBoundary(in: cogs)
      return phase
    }

    /// Reads an async cog's current phase without creating a dependency edge.
    ///
    /// A first one-shot read starts the initial work. Because the read
    /// installs no durable consumer, it also starts the declaration's
    /// ordinary `whileObserved` grace. The state owns at most one grace
    /// sleeper; another one-shot read cancels and replaces it without
    /// replacing work already in flight. The returned phase is fully settled
    /// at the latest completed turn, just like a tracked read; only future
    /// invalidation is intentionally omitted. No Swift Observation boundary
    /// or reaction lease is created.
    ///
    /// - Parameter valueReference: The async declaration and optional key to
    ///   inspect.
    /// - Returns: Its current full phase, beginning with pending on first
    ///   demand.
    public func peek<Value>(_ valueReference: AsyncCog<Value>) -> CogPhase<Value> {
      let state = cogs.asyncState(for: valueReference)
      let phase = state.settledPhase(in: cogs)
      cogs.scheduleLifetimeReleaseIfUnobserved(state)
      return phase
    }
  }
}
