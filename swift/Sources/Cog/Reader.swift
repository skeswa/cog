public import Observation

/// The read capability inside one run of a selector.
///
/// This is the `c` in `Cog { c in ... }`.
///
/// ```swift
/// let subtotalCog = Cog<Money> { c in
///   let cart = c[cartCog]
///   return cart.items.reduce(.zero) { $0 + $1.price }
/// }
/// ```
///
/// Application selectors bind each read to the value reference's unsuffixed
/// domain name before using it. `c[valueReference]` returns a value and records
/// its dependency. Each run
/// replaces the dependency set, so branches and early returns work as expected.
/// Reads made outside this reader are invisible to Cog.
///
/// A ``Cog/Async`` selector receives a `Reader<CogStatus<Value>>`. Its tracked
/// reads finish synchronously while the selector builds ``Work``; code in the
/// work closure runs after dependency capture and cannot add edges through this
/// reader.
///
/// A reader is valid only during its selector run. Using a saved reader later
/// traps. The type and every access are MainActor-isolated; selector execution,
/// dependency mutation, and nested settlement are synchronous even when the
/// selector is choosing later asynchronous ``Work``.
///
/// `c.peek` skips dependency tracking. `c.curr` returns this cog's previous
/// value without creating a self-dependency.
@MainActor
public struct Reader<Value> {
  /// The context whose graph this run reads.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  internal let cogs: Cogs

  /// Arena consumer slot for this data-oriented selector.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  internal let arenaState: CogArenaSlot

  /// Hands an arena-automatic row its scoped read capability.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  internal init(cogs: Cogs, arenaState: CogArenaSlot) {
    self.cogs = cogs
    self.arenaState = arenaState
  }

  /// Reads a source, and depends on it.
  ///
  /// This uses the source value from the latest completed turn and records its
  /// exact descriptor-and-key state in the current selector's replacement
  /// dependency set. It does not register Swift Observation access.
  ///
  /// - Parameter valueReference: The source to read.
  /// - Returns: The value from the latest completed turn.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  public subscript<Read>(_ valueReference: Cog<Read>.Manual) -> Read {
    let consumer = requiredArenaState()
    return cogs.arenaCore.read(valueReference, for: consumer)
  }

  /// Reads another automatic cog, and depends on it.
  ///
  /// The producer and any dirty dependencies settle before the edge is recorded
  /// and the value is returned. The first read computes the automatic cog; unread
  /// branches remain lazy. Later invalidation reruns this selector only when the
  /// producer's equality policy reports a changed value.
  ///
  /// - Parameter valueReference: The automatic cog to read.
  /// - Returns: Its value in this context.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  public subscript<Read>(_ valueReference: Cog<Read>) -> Read {
    let consumer = requiredArenaState()
    return cogs.arenaCore.read(valueReference, for: consumer, in: cogs)
  }

  /// Reads an async cog's value and depends on it.
  ///
  /// This is a total read: it returns the last accepted success, or the
  /// declaration's resting default before one exists. The read resolves
  /// through the async cog's internal value projection, so it settles like
  /// any automatic read — a first read creates the async state, starts its
  /// work, and returns the default while that work runs. Equality gating on
  /// the projection keeps this selector quiet when a reload succeeds with an
  /// equal value; read `c.status[valueReference]` instead where the request
  /// lifecycle itself matters. If initial demand establishes pending during
  /// this selector, Cog defers the graph-owned pending flush until tracking
  /// and settlement exit, so Observation and reactions cannot reenter this
  /// run.
  ///
  /// - Parameter valueReference: The async value to read.
  /// - Returns: Its newest settled value in this context.
  public subscript<Read>(_ valueReference: Cog<Read>.Async) -> Read {
    self[valueReference.valueCog]
  }

  /// The status lens over this reader: the same tracked-read capability,
  /// returning full ``CogStatus`` values for async references.
  ///
  /// `c.status[asyncValue]` records a dependency on the async state itself, so
  /// later pending, success, and failure turns each rerun this selector even
  /// when the successful value is unchanged — the opposite gating from the
  /// value read beside it. The lens deliberately has no spelling for manual
  /// or automatic cogs: synchronous state has no request status, and asking for it is a
  /// type error rather than a degenerate success.
  public var status: Status {
    Status(cogs: cogs, arenaState: requiredArenaState())
  }

  /// The tracked status-reading facet of one selector run.
  ///
  /// A lens is as transient as the reader that made it: it borrows the same
  /// context and computing consumer, enforces the same active-tracking
  /// requirement on every access, and is invalid outside its selector run.
  @MainActor
  public struct Status {
    /// The context whose graph this run reads.
    private let cogs: Cogs

    /// The computing arena row receiving status dependencies.
    private let arenaState: CogArenaSlot

    /// Borrows the reader's capability for status spellings.
    internal init(cogs: Cogs, arenaState: CogArenaSlot) {
      self.cogs = cogs
      self.arenaState = arenaState
    }

    /// Reads an async cog's full status and depends on its exact state.
    ///
    /// Cog settles the producer before recording the edge. A first read
    /// therefore selects its work and returns pending, while a dirty producer
    /// selects its replacement work before this selector observes the status.
    /// Recording the edge makes later pending, success, and failure turns
    /// invalidate this selector and keeps a `whileObserved` producer reachable
    /// through the automatic dependency graph. If initial demand establishes
    /// pending during this selector, Cog defers the graph-owned pending flush
    /// until tracking and settlement exit, so Observation and reactions cannot
    /// reenter this run.
    ///
    /// - Parameter valueReference: The async value whose status to read.
    /// - Returns: Its newest settled status in this context.
    public subscript<Read>(_ valueReference: Cog<Read>.Async) -> CogStatus<Read> {
      return cogs.arenaCore.readAsyncStatus(
        descriptor: valueReference.descriptor,
        key: valueReference.key,
        for: arenaState,
        in: cogs
      )
    }

    /// Peeks at an async cog's status without recording a dependency.
    ///
    /// The read still settles the exact state, starting initial work or
    /// selecting replacement work when needed. It records no edge from this
    /// selector, so later status turns do not rerun it, and with no other
    /// durable consumer the one-shot read starts or renews the async state's
    /// ordinary `whileObserved` grace.
    ///
    /// - Parameter valueReference: The async value whose status to read
    ///   without tracking it.
    /// - Returns: Its newest settled status in this context.
    public func peek<Read>(_ valueReference: Cog<Read>.Async) -> CogStatus<Read> {
      cogs.arenaCore.requireTracking(arenaState)
      return cogs.status.peek(valueReference)
    }
  }

  /// Reads one async descriptor for an internal projection selector.
  ///
  /// The internal value projection has the descriptor and key rather than another
  /// public value reference. This path resolves that same exact async state,
  /// settles it before recording the projection's dependency, and returns the
  /// status from which the projection computes its total value. Keeping
  /// the operation here preserves the public reader's tracking and escaped-use
  /// checks for the package-only projection implementation. A cold read follows
  /// the same deferred system-turn rule as the public async subscript, so the
  /// projection cannot flush through its own active automatic computation.
  ///
  /// - Parameters:
  ///   - descriptor: The async declaration shared with the projection.
  ///   - key: The keyed state to read, or `nil` for a keyless declaration.
  /// - Returns: The exact async state's newest settled status.
  internal func asyncStatus<Read>(
    from descriptor: AsyncCogDescriptor<Read>,
    key: CogKey?
  ) -> CogStatus<Read> {
    return cogs.arenaCore.readAsyncStatus(
      descriptor: descriptor,
      key: key,
      for: requiredArenaState(),
      in: cogs
    )
  }

  /// Reads a source exposed through `.readOnly`, and depends on it.
  ///
  /// This lets a selector read a published projection while the writable
  /// source stays `fileprivate` in its owning file.
  /// The projection and source share one state identity and dependency edge.
  ///
  /// - Parameter valueReference: The read-only projection to read.
  /// - Returns: The value its source holds in the latest completed turn.
  public subscript<Read>(_ valueReference: Cog<Read>.Projection) -> Read {
    self[valueReference.sourceCog]
  }

  /// Links one property of an external observable model into this selector.
  ///
  /// The returned value participates in the current selector run exactly like
  /// a Cog source read. On iOS 26 and its peer 26-era platforms,
  /// `Observations` tracks only `keyPath`, coalesces mutations until the model
  /// isolation reaches a suspension boundary, and publishes the newest value
  /// in a named Cog turn. A sibling property therefore creates no invalidation
  /// or selector work.
  ///
  /// On older runtimes, `withObservationTracking` is one-shot and reports a
  /// change from `willSet`. Cog defers that callback onto the MainActor, then
  /// re-arms and reads after the setter completes before publishing. There is
  /// necessarily a small disarmed window between the callback and re-arm; a
  /// mutation made inside that window may be missed. Cog guarantees the newest
  /// post-mutation value only for a mutation made after re-arm completes.
  ///
  /// The model and property stay on the MainActor with Cog. `Tracked` need not
  /// be `Sendable`: the Observation sequence emits only a wakeup, then Cog
  /// reads and publishes the actual value on the captured actor.
  ///
  /// - Parameters:
  ///   - root: The external `@Observable` model to link.
  ///   - keyPath: The exact property this selector reads and depends on.
  /// - Returns: The latest value published at an observation boundary, or the
  ///   model's current value on the first read.
  public func track<Root: Observable & AnyObject, Tracked>(
    _ root: Root,
    _ keyPath: KeyPath<Root, Tracked>
  ) -> Tracked {
    let sourceCog = cogs.trackedPropertySource(for: root, keyPath: keyPath)
    return self[sourceCog]
  }

  /// Links a synchronous external Observation read into this selector.
  ///
  /// Use this form when one value reads several properties of the same external
  /// model or otherwise cannot be expressed by one key path:
  ///
  /// ```swift
  /// let displayNameCog = Cog<String> { c in
  ///   c.track(profile) { profile in
  ///     "\(profile.givenName) \(profile.familyName)"
  ///   }
  /// }
  /// ```
  ///
  /// Observation records every property read synchronously by `read`. The iOS
  /// 26 path coalesces those properties at suspension boundaries; the legacy
  /// path has the same post-setter re-arm semantics and documented disarmed
  /// window as the key-path overload. Each selector and source call site owns
  /// one bridge. On a selector rerun, Cog replaces its captured closure and
  /// re-arms synchronously so changing captured inputs cannot leave tracking on
  /// an earlier property set.
  ///
  /// `Tracked` need not be `Sendable`; the read and publication stay on the
  /// MainActor. Keep every external model the closure touches on that actor.
  ///
  /// - Parameters:
  ///   - root: The primary external `@Observable` model retained by the bridge.
  ///   - fileID: Source identity supplied by the compiler.
  ///   - line: Source identity supplied by the compiler.
  ///   - column: Source identity supplied by the compiler.
  ///   - read: Synchronous read whose Observation accesses form the dependency.
  /// - Returns: The newest value from the current observation boundary.
  public func track<Root: Observable & AnyObject, Tracked>(
    _ root: Root,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    column: UInt = #column,
    read: @escaping @MainActor (Root) -> Tracked
  ) -> Tracked {
    let consumer = externalObservationConsumerIdentity()
    let tracked = cogs.trackedClosureSource(
      for: consumer,
      fileID: String(describing: fileID),
      line: line,
      column: column,
      read: { read(root) }
    )
    _ = self[tracked.sourceCog]
    return tracked.value
  }

  /// Peeks at a source without depending on it.
  ///
  /// Use this when the selector needs the source's current value but only a
  /// different tracked input should make the selector run again.
  ///
  /// - Parameter valueReference: The source to read without recording an edge.
  /// - Returns: The value the source holds in the latest completed turn.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  public func peek<Read>(_ valueReference: Cog<Read>.Manual) -> Read {
    cogs.arenaCore.requireTracking(requiredArenaState())
    return cogs.peek(valueReference)
  }

  /// Peeks at an automatic cog without depending on it.
  ///
  /// Skipping the edge never returns stale data. If the automatic cog is dirty,
  /// this call settles it before returning, but its later changes do not make
  /// this selector run again. Because no durable consumer is installed, a
  /// default `whileObserved` state starts or renews its ordinary grace window.
  ///
  /// - Parameter valueReference: The automatic cog to read without recording an edge.
  /// - Returns: Its newest settled value in this context.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  public func peek<Read>(_ valueReference: Cog<Read>) -> Read {
    cogs.arenaCore.requireTracking(requiredArenaState())
    return cogs.peek(valueReference)
  }

  /// Peeks at an async cog's value without depending on it.
  ///
  /// This remains a current, total read: it settles dirty state, and a first
  /// peek selects work and returns the declaration's resting default while
  /// that work runs. It records no edge from this selector, so later turns do
  /// not rerun the selector. With no other durable consumer, the one-shot
  /// read starts or renews the async state's ordinary `whileObserved` grace
  /// rather than keeping it alive indefinitely.
  ///
  /// - Parameter valueReference: The async value to read without tracking it.
  /// - Returns: Its newest settled value in this context.
  public func peek<Read>(_ valueReference: Cog<Read>.Async) -> Read {
    cogs.arenaCore.requireTracking(requiredArenaState())
    return cogs.peek(valueReference)
  }

  /// Peeks at a source exposed through `.readOnly` without depending on it.
  ///
  /// The projection and source share one identity; this spelling only preserves
  /// the source's write encapsulation.
  ///
  /// - Parameter valueReference: The read-only projection to read without recording an
  ///   edge.
  /// - Returns: The value its source holds in the latest completed turn.
  public func peek<Read>(_ valueReference: Cog<Read>.Projection) -> Read {
    peek(valueReference.sourceCog)
  }

  /// The value this cog retained after its previous completed run.
  ///
  /// The outer optional records whether a previous run exists. If `Value` is
  /// itself optional, `.none` means there has been no previous run while
  /// `.some(.none)` means the previous run produced `nil`.
  /// Reading `curr` never records a self-dependency or triggers settlement.
  ///
  /// - Returns: The cached value from this state's previous completed selector
  ///   run, or `nil` when no run has completed.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  public var curr: Value? {
    return cogs.arenaCore.previousValue(for: requiredArenaState(), as: Value.self)
  }

  /// The cycle a read of `valueReference` would close during this selector run.
  ///
  /// Package-only so the shipping Cog product exposes no diagnostic API.
  /// CogTesting wraps the rendered snapshot as its narrow public test seam.
  ///
  /// - Parameter valueReference: The automatic value whose hypothetical read
  ///   should be checked against the active settlement path.
  /// - Returns: A rendered cycle snapshot if that read would close a cycle;
  ///   otherwise `nil`.
  package func cycleDiagnosticSnapshot<Read>(
    ifReading valueReference: Cog<Read>
  ) -> CogCycleDiagnosticSnapshot? {
    cogs.arenaCore.requireTracking(requiredArenaState())
    return cogs.cycleDiagnosticSnapshot(ifReading: valueReference)
  }

  /// Names the exact selector consumer that owns a closure-form observer.
  private func externalObservationConsumerIdentity()
    -> CogExternalObservationConsumerIdentity
  {
    cogs.arenaCore.requireTracking(arenaState)
    return .arena(arenaState)
  }

  /// Restores the indexed consumer carried by an arena-core reader.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  internal func requiredArenaState() -> CogArenaSlot {
    return arenaState
  }
}
