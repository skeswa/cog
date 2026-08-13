/// The metadata lens over a context: the UI-boundary and one-shot read
/// capability for async request lifecycles.
///
/// `cogs.meta[valueReference]` is the opt-in spelling for the full
/// ``CogMeta`` — pending, success, and failure, each its own turn — beside
/// the total value read `cogs[valueReference]`. The lens carries the same
/// read family as the value spelling: a tracked subscript, a non-tracking
/// `peek`, and a `watch`, with identical demand,
/// tracking, and lifetime rules. It deliberately has no spelling for manual
/// or derived cogs: synchronous state has no request metadata, so asking for it is a
/// type error rather than a degenerate success.
extension Cogs {
  /// The lens for UI-boundary and one-shot metadata reads.
  ///
  /// Accessing the property is inert; only the lens's reads touch the graph.
  public var meta: Meta {
    Meta(cogs: self)
  }

  /// The metadata-reading facet of one context.
  ///
  /// A lens is a transient borrow of its context's read capability — it holds
  /// no state of its own and creates none until one of its reads demands an
  /// async value.
  @MainActor
  public struct Meta {
    /// The context whose async states this lens reads.
    internal let cogs: Cogs

    /// Reads an async cog's full metadata through the Observation boundary.
    ///
    /// The read first settles the exact descriptor-and-key state. A first
    /// read therefore selects work and publishes pending before returning; a
    /// dirty state selects replacement work before its current metadata is
    /// observed. Only after settlement does Cog register the Observation
    /// access, so the boundary tracks the metadata returned by this call rather
    /// than receiving a redundant notice for the initial pending publication.
    ///
    /// This is UI tracking, not a selector or reaction dependency edge.
    /// Creating the boundary pins the state against `whileObserved` release,
    /// and later pending, success, or failure turns notify the active
    /// Observation consumer — including a reload that succeeds with an equal
    /// value, which the value read beside this lens would gate away.
    ///
    /// - Parameter valueReference: The async value whose metadata the UI reads.
    /// - Returns: The newest settled metadata in this context.
    public subscript<Value>(_ valueReference: AsyncCog<Value>) -> CogMeta<Value> {
      let state = cogs.asyncState(for: valueReference)
      let meta = state.settledMeta(in: cogs)
      state.accessObservationBoundary(in: cogs)
      return meta
    }

    /// Reads an async cog's current metadata without creating a dependency edge.
    ///
    /// A first one-shot read starts the initial work. Because the read
    /// installs no durable consumer, it also starts the declaration's
    /// ordinary `whileObserved` grace. The state owns at most one grace
    /// sleeper; another one-shot read cancels and replaces it without
    /// replacing work already in flight. The returned metadata is fully settled
    /// at the latest completed turn, just like a tracked read; only future
    /// invalidation is intentionally omitted. No Swift Observation boundary
    /// or reaction lease is created.
    ///
    /// - Parameter valueReference: The async declaration and optional key to
    ///   inspect.
    /// - Returns: Its current full metadata, beginning with pending on first
    ///   demand.
    public func peek<Value>(_ valueReference: AsyncCog<Value>) -> CogMeta<Value> {
      let state = cogs.asyncState(for: valueReference)
      let meta = state.settledMeta(in: cogs)
      cogs.scheduleLifetimeReleaseIfUnobserved(state)
      return meta
    }
  }
}
