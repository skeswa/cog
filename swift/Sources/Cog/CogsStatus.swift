/// The status lens over a context: the UI-boundary and one-shot read
/// capability for async request lifecycles.
///
/// `cogs.status[valueReference]` is the opt-in spelling for the full
/// ``CogStatus`` — its kind and associated fields, updated in one turn — beside
/// the total value read `cogs[valueReference]`. The lens carries the same
/// read family as the value spelling: a tracked subscript, a non-tracking
/// `peek`, and a `watch`, with identical demand and lifetime rules. The UI
/// subscript tracks each returned field independently; selector and reaction
/// reads and explicit watches track the complete status. The lens deliberately
/// has no spelling for manual or automatic cogs: synchronous state has no request
/// status, so asking for it is a type error rather than a degenerate success.
///
/// Bind the result to the declaration's unsuffixed domain name, just like a
/// plain value read:
///
/// ```swift
/// let forecast = cogs.status[forecastCog]
/// if forecast.kind == .failure {
///   showRetry(forecast.error)
/// }
/// ```
///
/// The `CogStatus` type carries the lifecycle distinction; a `forecastStatus`
/// suffix is unnecessary. Creating the local observes no status field. The
/// later getters above independently register only `kind` and `error`.
extension Cogs {
  /// The lens for UI-boundary and one-shot status reads.
  ///
  /// Accessing the property is inert; only the lens's reads touch the graph.
  public var status: Status {
    Status(cogs: self)
  }

  /// The status-reading facet of one context.
  ///
  /// A lens is a transient borrow of its context's read capability — it holds
  /// no state of its own and creates none until one of its reads demands an
  /// async value.
  @MainActor
  public struct Status {
    /// The context whose async states this lens reads.
    internal let cogs: Cogs

    /// Reads an async cog's full status through the Observation boundary.
    ///
    /// The read first settles the exact descriptor-and-key state. A first
    /// read therefore selects work and publishes pending before returning; a
    /// dirty state selects replacement work before its current status is
    /// observed. Only after settlement does Cog register the Observation
    /// access. The returned status attaches the state's stable boundary, and
    /// each field getter records its own key path only if the caller uses it.
    /// Initial pending therefore becomes the baseline without a redundant
    /// notice, while later turns invalidate only fields whose values changed.
    ///
    /// This is UI tracking, not a selector or reaction dependency edge.
    /// Creating the boundary pins the state against `whileObserved` release,
    /// and later pending, success, or failure turns notify active field
    /// consumers only where their projected values changed. An equal-success
    /// reload therefore changes `kind` and `isLoading` while leaving `value`
    /// quiet under the same equality rule as the value read beside this lens.
    ///
    /// - Parameter valueReference: The async value whose status the UI reads.
    /// - Returns: The newest settled status in this context.
    public subscript<Value>(_ valueReference: Cog<Value>.Async) -> CogStatus<Value> {
      return cogs.arenaCore.observedAsyncStatus(for: valueReference, in: cogs)
    }

    /// Reads an async cog's current status without creating a dependency edge.
    ///
    /// A first one-shot read starts the initial work. Because the read
    /// installs no durable consumer, it also starts the declaration's
    /// ordinary `whileObserved` grace. The state owns at most one grace
    /// sleeper; another one-shot read cancels and replaces it without
    /// replacing work already in flight. The returned status is fully settled
    /// at the latest completed turn, just like a tracked read; only future
    /// invalidation is intentionally omitted. No Swift Observation boundary
    /// or reaction lease is created.
    ///
    /// - Parameter valueReference: The async declaration and optional key to
    ///   inspect.
    /// - Returns: Its current full status, beginning with pending on first
    ///   demand.
    public func peek<Value>(_ valueReference: Cog<Value>.Async) -> CogStatus<Value> {
      let status = cogs.arenaCore.asyncStatus(for: valueReference, in: cogs)
      cogs.arenaCore.scheduleLifetimeReleaseIfUnobserved(for: valueReference, in: cogs)
      return status
    }
  }
}
