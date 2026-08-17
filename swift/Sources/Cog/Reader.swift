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
/// An ``AsyncCog`` selector receives a `Reader<CogStatus<Value>>`. Its tracked
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
  private let cogs: Cogs

  #if COG_CORE_ARENA
  /// Transitional class-state consumer used by arena paths not migrated yet.
  private let state: (any CogReaderState<Value>)?

  /// Arena consumer slot for a migrated data-oriented selector.
  private let arenaState: CogArenaSlot?
  #else
  /// The class state receiving dependencies and providing `curr`.
  private let state: any CogReaderState<Value>
  #endif

  /// Hands a computing state its scoped read capability.
  ///
  /// `requireTracking` on every public access enforces that `state` is still the
  /// context's active consumer, so retaining this value cannot extend a tracking
  /// region.
  ///
  /// - Parameters:
  ///   - cogs: The one context whose graph is being evaluated.
  ///   - state: The computing consumer that receives dependency edges and
  ///     provides ``curr``.
  internal init(cogs: Cogs, state: some CogReaderState<Value>) {
    self.cogs = cogs
    self.state = state
    #if COG_CORE_ARENA
    self.arenaState = nil
    #endif
  }

  #if COG_CORE_ARENA
  /// Hands an arena-derived row its scoped read capability.
  internal init(cogs: Cogs, arenaState: CogArenaSlot) {
    self.cogs = cogs
    self.state = nil
    self.arenaState = arenaState
  }
  #endif

  /// Reads a source, and depends on it.
  ///
  /// This uses the source value from the latest completed turn and records its
  /// exact descriptor-and-key state in the current selector's replacement
  /// dependency set. It does not register Swift Observation access.
  ///
  /// - Parameter valueReference: The source to read.
  /// - Returns: The value from the latest completed turn.
  public subscript<Read>(_ valueReference: ManualCog<Read>) -> Read {
    #if COG_CORE_ARENA
    let consumer = requiredArenaState()
    return cogs.arenaCore.read(valueReference, for: consumer)
    #else
    let state = requiredSimpleState()
    cogs.requireTracking(state)
    let producer = cogs.manualState(for: valueReference)
    state.recordDependency(on: producer)
    return producer.currentValue
    #endif
  }

  /// Reads another derived cog, and depends on it.
  ///
  /// The producer and any dirty dependencies settle before the edge is recorded
  /// and the value is returned. The first read computes the derived cog; unread
  /// branches remain lazy. Later invalidation reruns this selector only when the
  /// producer's equality policy reports a changed value.
  ///
  /// - Parameter valueReference: The derived cog to read.
  /// - Returns: Its value in this context.
  public subscript<Read>(_ valueReference: Cog<Read>) -> Read {
    #if COG_CORE_ARENA
    let consumer = requiredArenaState()
    return cogs.arenaCore.read(valueReference, for: consumer, in: cogs)
    #else
    let state = requiredSimpleState()
    cogs.requireTracking(state)
    let producer = cogs.derivedState(for: valueReference)
    state.recordDependency(on: producer)
    return producer.settledValue(in: cogs)
    #endif
  }

  /// Reads an async cog's value and depends on it.
  ///
  /// This is a total read: it returns the last accepted success, or the
  /// declaration's resting default before one exists. The read resolves
  /// through the async cog's internal value projection, so it settles like
  /// any derived read — a first read creates the async state, starts its
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
  public subscript<Read>(_ valueReference: AsyncCog<Read>) -> Read {
    self[valueReference.valueCog]
  }

  /// The status lens over this reader: the same tracked-read capability,
  /// returning full ``CogStatus`` values for async references.
  ///
  /// `c.status[asyncValue]` records a dependency on the async state itself, so
  /// later pending, success, and failure turns each rerun this selector even
  /// when the successful value is unchanged — the opposite gating from the
  /// value read beside it. The lens deliberately has no spelling for manual
  /// or derived cogs: synchronous state has no request status, and asking for it is a
  /// type error rather than a degenerate success.
  public var status: Status {
    #if COG_CORE_ARENA
    Status(cogs: cogs, arenaState: requiredArenaState())
    #else
    Status(cogs: cogs, state: requiredSimpleState())
    #endif
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

    #if COG_CORE_ARENA
    /// The computing arena row receiving status dependencies.
    private let arenaState: CogArenaSlot
    #else
    /// The computing class-state consumer receiving status dependencies.
    private let state: any CogReaderState<Value>
    #endif

    /// Borrows the reader's capability for status spellings.
    #if COG_CORE_ARENA
    internal init(cogs: Cogs, arenaState: CogArenaSlot) {
      self.cogs = cogs
      self.arenaState = arenaState
    }
    #else
    internal init(cogs: Cogs, state: any CogReaderState<Value>) {
      self.cogs = cogs
      self.state = state
    }
    #endif

    /// Reads an async cog's full status and depends on its exact state.
    ///
    /// Cog settles the producer before recording the edge. A first read
    /// therefore selects its work and returns pending, while a dirty producer
    /// selects its replacement work before this selector observes the status.
    /// Recording the edge makes later pending, success, and failure turns
    /// invalidate this selector and keeps a `whileObserved` producer reachable
    /// through the derived dependency graph. If initial demand establishes
    /// pending during this selector, Cog defers the graph-owned pending flush
    /// until tracking and settlement exit, so Observation and reactions cannot
    /// reenter this run.
    ///
    /// - Parameter valueReference: The async value whose status to read.
    /// - Returns: Its newest settled status in this context.
    public subscript<Read>(_ valueReference: AsyncCog<Read>) -> CogStatus<Read> {
      #if COG_CORE_ARENA
      return cogs.arenaCore.readAsyncStatus(
        descriptor: valueReference.descriptor,
        key: valueReference.key,
        for: arenaState,
        in: cogs
      )
      #else
      cogs.requireTracking(state)

      let producer = cogs.asyncState(for: valueReference)
      let status = producer.settledStatus(in: cogs)
      state.recordDependency(on: producer)
      return status
      #endif
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
    public func peek<Read>(_ valueReference: AsyncCog<Read>) -> CogStatus<Read> {
      #if COG_CORE_ARENA
      cogs.arenaCore.requireTracking(arenaState)
      #else
      cogs.requireTracking(state)
      #endif
      return cogs.status.peek(valueReference)
    }
  }

  /// Reads one async descriptor for an internal projection selector.
  ///
  /// The internal value projection has the descriptor and key rather than another
  /// public value reference. This path resolves that same exact async state,
  /// settles it before recording the projection's dependency, and returns the
  /// status from which the projection derives its total value. Keeping
  /// the operation here preserves the public reader's tracking and escaped-use
  /// checks for the package-only projection implementation. A cold read follows
  /// the same deferred system-turn rule as the public async subscript, so the
  /// projection cannot flush through its own active derivation.
  ///
  /// - Parameters:
  ///   - descriptor: The async declaration shared with the projection.
  ///   - key: The keyed state to read, or `nil` for a keyless declaration.
  /// - Returns: The exact async state's newest settled status.
  internal func asyncStatus<Read>(
    from descriptor: AsyncCogDescriptor<Read>,
    key: CogKey?
  ) -> CogStatus<Read> {
    #if COG_CORE_ARENA
    return cogs.arenaCore.readAsyncStatus(
      descriptor: descriptor,
      key: key,
      for: requiredArenaState(),
      in: cogs
    )
    #else
    let state = requiredSimpleState()
    cogs.requireTracking(state)

    let producer = cogs.asyncState(descriptor: descriptor, key: key)
    let status = producer.settledStatus(in: cogs)
    state.recordDependency(on: producer)
    return status
    #endif
  }

  /// Reads a source exposed through `.readOnly`, and depends on it.
  ///
  /// This lets a selector read a published projection while the writable
  /// source stays `fileprivate` in its owning file.
  /// The projection and source share one state identity and dependency edge.
  ///
  /// - Parameter valueReference: The read-only projection to read.
  /// - Returns: The value its source holds in the latest completed turn.
  public subscript<Read>(_ valueReference: CogProjection<Read>) -> Read {
    self[valueReference.sourceCog]
  }

  /// Peeks at a source without depending on it.
  ///
  /// Use this when the selector needs the source's current value but only a
  /// different tracked input should make the selector run again.
  ///
  /// - Parameter valueReference: The source to read without recording an edge.
  /// - Returns: The value the source holds in the latest completed turn.
  public func peek<Read>(_ valueReference: ManualCog<Read>) -> Read {
    #if COG_CORE_ARENA
    cogs.arenaCore.requireTracking(requiredArenaState())
    #else
    let state = requiredSimpleState()
    cogs.requireTracking(state)
    #endif
    return cogs.peek(valueReference)
  }

  /// Peeks at a derived cog without depending on it.
  ///
  /// Skipping the edge never returns stale data. If the derived cog is dirty,
  /// this call settles it before returning, but its later changes do not make
  /// this selector run again. Because no durable consumer is installed, a
  /// default `whileObserved` state starts or renews its ordinary grace window.
  ///
  /// - Parameter valueReference: The derived cog to read without recording an edge.
  /// - Returns: Its newest settled value in this context.
  public func peek<Read>(_ valueReference: Cog<Read>) -> Read {
    #if COG_CORE_ARENA
    cogs.arenaCore.requireTracking(requiredArenaState())
    #else
    let state = requiredSimpleState()
    cogs.requireTracking(state)
    #endif
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
  public func peek<Read>(_ valueReference: AsyncCog<Read>) -> Read {
    #if COG_CORE_ARENA
    cogs.arenaCore.requireTracking(requiredArenaState())
    #else
    let state = requiredSimpleState()
    cogs.requireTracking(state)
    #endif
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
  public func peek<Read>(_ valueReference: CogProjection<Read>) -> Read {
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
  public var curr: Value? {
    #if COG_CORE_ARENA
    return cogs.arenaCore.previousValue(for: requiredArenaState(), as: Value.self)
    #else
    let state = requiredSimpleState()
    cogs.requireTracking(state)
    return state.readerCurrentValue
    #endif
  }

  /// The cycle a read of `valueReference` would close during this selector run.
  ///
  /// Package-only so the shipping Cog product exposes no diagnostic API.
  /// CogTesting wraps the rendered snapshot as its narrow public test seam.
  ///
  /// - Parameter valueReference: The derived value whose hypothetical read
  ///   should be checked against the active settlement path.
  /// - Returns: A rendered cycle snapshot if that read would close a cycle;
  ///   otherwise `nil`.
  package func cycleDiagnosticSnapshot<Read>(
    ifReading valueReference: Cog<Read>
  ) -> CogCycleDiagnosticSnapshot? {
    #if COG_CORE_ARENA
    cogs.arenaCore.requireTracking(requiredArenaState())
    #else
    let state = requiredSimpleState()
    cogs.requireTracking(state)
    #endif
    return cogs.cycleDiagnosticSnapshot(ifReading: valueReference)
  }

  /// Restores the class-state consumer carried by a simple-core reader.
  private func requiredSimpleState() -> any CogReaderState<Value> {
    #if COG_CORE_ARENA
    guard let state else {
      fatalError("This Cog reader belongs to an arena selector, not a class-state selector.")
    }
    #endif
    return state
  }

  #if COG_CORE_ARENA
  /// Restores the indexed consumer carried by an arena-core reader.
  private func requiredArenaState() -> CogArenaSlot {
    guard let arenaState else {
      fatalError("This Cog reader belongs to a class-state selector, not an arena selector.")
    }
    return arenaState
  }
  #endif
}
