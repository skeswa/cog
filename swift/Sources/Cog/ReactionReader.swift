/// The read capability inside one run of a reaction.
///
/// This is the `c` in `m.run { c in ... }`. Reading through the subscript
/// both returns the latest settled value and records it as a dependency of the
/// reaction run in progress. A later turn reruns the reaction only when one of
/// those dependencies changes.
///
/// `c.peek(valueReference)` returns a current settled value without recording
/// it as a dependency.
///
/// Every tracking run replaces the reaction's dependency set. A tracked read of
/// a `whileObserved` automatic or async state also gives the reaction a durable
/// lease on that exact root. Peeking does not; async peek is one-shot demand and
/// uses the state's grace policy when nothing else observes it.
///
/// To write, call an op on the context. Its turn runs as a new turn after the
/// active flush. Like ``Reader``, this value is valid only during its run, and
/// saved use traps. The reader, body, graph access, and dependency reconciliation
/// are all MainActor-isolated and synchronous.
@MainActor
public struct ReactionReader {
  /// The context whose active reaction run owns this capability.
  private let cogs: Cogs

  /// The exact registration receiving dependencies and lifetime leases.
  private let reaction: CogReaction

  /// Creates the scoped capability for one active reaction run.
  ///
  /// Public accessors verify that `reaction` is still the context's tracked
  /// consumer, preventing an escaped reader from mutating dependencies later.
  ///
  /// - Parameters:
  ///   - cogs: The context evaluating the reaction.
  ///   - reaction: The active registration that receives dependency edges.
  internal init(cogs: Cogs, reaction: CogReaction) {
    self.cogs = cogs
    self.reaction = reaction
  }

  /// Reads a source and records it as a dependency of this reaction run.
  ///
  /// The value comes from the latest completed turn. A later changed source
  /// turn schedules this reaction after mutation closes; no Swift Observation
  /// boundary is involved.
  ///
  /// - Parameter valueReference: The source identity to track.
  /// - Returns: Its current completed-turn value.
  public subscript<Value>(_ valueReference: ManualCog<Value>) -> Value {
    cogs.arenaCore.requireTracking(reaction.arenaSlot)

    guard !reaction.isCancelled else { return cogs.peek(valueReference) }
    return cogs.arenaCore.read(valueReference, for: reaction.arenaSlot)
  }

  /// Reads an automatic cog and records it as a dependency of this reaction run.
  ///
  /// Cog settles the producer and its dirty dependencies before returning. A
  /// later equality-confirmed change schedules this reaction, while an equal
  /// recomputation stops the wave. The registration holds the exact automatic
  /// root's `whileObserved` lease until a later run drops the edge or the token
  /// is cancelled.
  ///
  /// - Parameter valueReference: The automatic identity to settle and track.
  /// - Returns: Its newest fully settled value.
  public subscript<Value>(_ valueReference: Cog<Value>) -> Value {
    cogs.arenaCore.requireTracking(reaction.arenaSlot)

    guard !reaction.isCancelled else { return cogs.peek(valueReference) }
    return cogs.arenaCore.read(valueReference, for: reaction.arenaSlot, in: cogs)
  }

  /// Reads an async cog's value and records it as a reaction dependency.
  ///
  /// This is a total read: it returns the last accepted success, or the
  /// declaration's resting default before one exists, resolving through the
  /// async cog's internal value projection. A first read creates the async
  /// state and starts its work; the reaction then holds a `whileObserved`
  /// lease that reaches the async state through the projection's dependency.
  /// Equality gating keeps the reaction quiet when a reload succeeds with an
  /// equal value; track `c.status[valueReference]` instead where each status
  /// turn should rerun the reaction. If initial demand establishes pending,
  /// Cog defers that graph-owned turn until tracking and lease reconciliation
  /// finish, so the turn cannot flush through the active reaction.
  ///
  /// - Parameter valueReference: The async value to track.
  /// - Returns: Its newest settled value in this context.
  public subscript<Value>(_ valueReference: AsyncCog<Value>) -> Value {
    self[valueReference.valueCog]
  }

  /// The status lens over this reaction's read capability.
  ///
  /// `c.status[asyncValue]` inside a reaction records the async state itself
  /// as the dependency, so every pending, success, and failure turn reruns
  /// the reaction — the opposite gating from the value read beside it. The
  /// lens has no spelling for manual or automatic cogs: synchronous state has
  /// no request status, and asking for it is a type error.
  public var status: Status {
    Status(cogs: cogs, reaction: reaction)
  }

  /// The tracked status-reading facet of one reaction run.
  ///
  /// As transient as the reader that made it: it borrows the same context
  /// and reaction, and every access enforces the same active-tracking
  /// requirement.
  @MainActor
  public struct Status {
    /// The context whose graph this reaction reads.
    private let cogs: Cogs

    /// The reaction receiving status dependencies and leases.
    private let reaction: CogReaction

    /// Borrows the reaction reader's capability for status spellings.
    internal init(cogs: Cogs, reaction: CogReaction) {
      self.cogs = cogs
      self.reaction = reaction
    }

    /// Reads an async cog's full status and records its exact state as a
    /// dependency.
    ///
    /// Cog settles the state before attaching the reaction edge. A first read
    /// can therefore select work and return pending; a dirty state selects
    /// fresh work before the reaction observes its status. At the end of the
    /// tracking run, the reaction acquires one `whileObserved` lease for the
    /// state. Later pending, success, or failure turns rerun the reaction
    /// after affected dependencies settle. Cancelling the reaction releases
    /// the lease and can begin grace. If initial demand establishes pending,
    /// Cog defers that graph-owned turn until tracking and lease
    /// reconciliation finish, so the turn cannot flush through the active
    /// reaction.
    ///
    /// - Parameter valueReference: The async value whose status to track.
    /// - Returns: Its newest settled status in this context.
    public subscript<Value>(_ valueReference: AsyncCog<Value>) -> CogStatus<Value> {
      cogs.arenaCore.requireTracking(reaction.arenaSlot)

      guard !reaction.isCancelled else { return cogs.status.peek(valueReference) }
      return cogs.arenaCore.readAsyncStatus(
        descriptor: valueReference.descriptor,
        key: valueReference.key,
        for: reaction.arenaSlot,
        in: cogs
      )
    }

    /// Peeks at an async cog's status without recording a dependency.
    ///
    /// The read still settles the exact state, starting initial work or
    /// selecting replacement work when needed. It does not add a reaction
    /// edge or lease, so later status turns do not rerun this reaction. If no
    /// other durable consumer exists, the peek starts or renews ordinary
    /// `whileObserved` grace.
    ///
    /// - Parameter valueReference: The async value whose status to read once.
    /// - Returns: Its newest settled status in this context.
    public func peek<Value>(_ valueReference: AsyncCog<Value>) -> CogStatus<Value> {
      cogs.arenaCore.requireTracking(reaction.arenaSlot)
      return cogs.status.peek(valueReference)
    }
  }

  /// Reads a source's read-only projection and records the source dependency.
  ///
  /// The projection and writable source share one state identity; this spelling
  /// preserves write encapsulation without changing tracking behavior.
  ///
  /// - Parameter valueReference: The read-only source projection to track.
  /// - Returns: Its source value from the latest completed turn.
  public subscript<Value>(_ valueReference: CogProjection<Value>) -> Value {
    self[valueReference.sourceCog]
  }

  /// Peeks at a source without recording it as a reaction dependency.
  ///
  /// The read is current but cannot schedule this reaction after a later turn
  /// and creates no Observation access.
  ///
  /// - Parameter valueReference: The source identity to read once.
  /// - Returns: Its value from the latest completed turn.
  public func peek<Value>(_ valueReference: ManualCog<Value>) -> Value {
    cogs.arenaCore.requireTracking(reaction.arenaSlot)
    return cogs.peek(valueReference)
  }

  /// Peeks at an automatic cog without recording it as a reaction dependency.
  ///
  /// A dirty value is settled before it is returned, but later changes do not
  /// schedule this reaction and no lifetime lease is acquired. If nothing else
  /// observes the default `whileObserved` state, the peek starts or renews its
  /// ordinary grace window.
  ///
  /// - Parameter valueReference: The automatic identity to settle and read once.
  /// - Returns: Its newest fully settled value.
  public func peek<Value>(_ valueReference: Cog<Value>) -> Value {
    cogs.arenaCore.requireTracking(reaction.arenaSlot)
    return cogs.peek(valueReference)
  }

  /// Peeks at an async cog's value without recording a dependency.
  ///
  /// The read is total and current: it settles the exact state, starting
  /// initial work when needed, and returns the resting default until the
  /// first success. It does not add a reaction edge or lease, so later turns
  /// do not rerun this reaction. If no other durable consumer exists, the
  /// peek starts or renews ordinary `whileObserved` grace.
  ///
  /// - Parameter valueReference: The async value to read once.
  /// - Returns: Its newest settled value in this context.
  public func peek<Value>(_ valueReference: AsyncCog<Value>) -> Value {
    cogs.arenaCore.requireTracking(reaction.arenaSlot)
    return cogs.peek(valueReference)
  }

  /// Peeks at a source's read-only projection without recording a dependency.
  ///
  /// The projection and source share one state identity; no reaction edge or
  /// Observation access is added.
  ///
  /// - Parameter valueReference: The read-only source projection to inspect.
  /// - Returns: Its source value from the latest completed turn.
  public func peek<Value>(_ valueReference: CogProjection<Value>) -> Value {
    peek(valueReference.sourceCog)
  }
}
