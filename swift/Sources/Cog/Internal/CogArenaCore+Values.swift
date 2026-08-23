// MARK: - Values

/// Typed source, automatic, async, and Observation-facing operations on the arena core.
///
/// These entry points resolve public descriptor-and-key identities before the
/// scalar settlement machinery takes over. Keeping that boundary together
/// makes the representation transition explicit without adding a helper object
/// or another call on steady reads and writes.
extension CogArenaCore {
  /// Stages one typed source and registers its row once with the active turn.
  ///
  /// Returns the resolved slot so the caller can hand it straight to the
  /// lifetime half without resolving the same descriptor-and-key identity a
  /// second time; each resolution retains the memoized typed column, and a
  /// steady turn should pay that once.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  @discardableResult
  func writerStage<Value>(
    _ valueReference: Cog<Value>.Manual,
    value: Value,
    in turn: CogTurn
  ) -> CogArenaSlot {
    let location = manualLocation(for: valueReference)
    location.column.stage(value, at: location.slot)
    touchArenaSource(location.slot, in: turn)
    return location.slot
  }

  /// Registers one staged arena source exactly once with its accumulating turn.
  ///
  /// Manual values and async statuses share the same scalar touched bit and
  /// ordered source list; their descriptor record restores the typed turn.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  func touchArenaSource(_ slot: CogArenaSlot, in turn: CogTurn) {
    let row = arena.index(of: slot)
    guard !arena.flags[row].contains(.touched) else { return }
    arena.flags[row].insert(.touched)
    turn.touchArenaSource(slot)
  }

  /// Publishes every source row touched by one arena turn.
  func flushPendingSources(_ touchedSources: ContiguousArray<CogArenaSlot>) {
    for slot in touchedSources {
      let row = arena.index(of: slot)
      guard arena.flags[row].contains(.touched) else {
        fatalError("Cog found an arena turn entry whose source was not touched.")
      }
      let record = descriptorRecord(forRow: row)
      guard record.kind != .automatic, let publishSource = record.publishSource else {
        fatalError("Cog tried to flush a non-source arena row as pending state.")
      }

      let changed = publishSource(slot, revision, propagation)
      #if DEBUG
      if changed, record.kind == .manual {
        recordHistoryState(event: .write, slot: slot)
      }
      #endif
      arena.flags[row].remove(.touched)
    }
  }

  /// Reads the pending overlay or current value of one source for a writer.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  func writerValue<Value>(for valueReference: Cog<Value>.Manual) -> Value {
    let location = manualLocation(for: valueReference)
    return location.column.writerValue(at: location.slot)
  }

  /// Reads one source without recording a dependency.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  func manualValue<Value>(for valueReference: Cog<Value>.Manual) -> Value {
    let location = manualLocation(for: valueReference)
    return location.column.current(at: location.slot)
  }

  #if DEBUG
  /// Publishes one pre-compared testing seed at the current arena revision.
  ///
  /// ``Cogs.seedForTesting(_:to:)`` owns the idle barrier, equality decision,
  /// and synchronized revision advance. This method updates only arena value
  /// and propagation columns, deliberately opening no turn or history event.
  /// An already-installed UI boundary remembers the quiet change so the next
  /// real turn can emit its one deferred notice without seed doing so itself.
  func publishTestingSeed<Value>(_ value: Value, for valueReference: Cog<Value>.Manual) {
    let location = manualLocation(for: valueReference)
    location.column.publishSeed(
      value,
      at: location.slot,
      revision: revision,
      propagatingWith: propagation
    )
    observationBoundary(for: location.slot)?.deferChange()
  }
  #endif

  /// Pulls one automatic value current without recording a dependency.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  func automaticValue<Value>(for valueReference: Cog<Value>, in cogs: Cogs) -> Value {
    let location = automaticLocation(for: valueReference)
    settle(location.slot, in: cogs)
    return location.column.current(at: location.slot)
  }

  /// Renews grace after one transient manual-source demand.
  ///
  /// The value operation stays pure so testing seeds and internal tracked reads
  /// cannot accidentally create a sleeper. Public `peek` and ordinary writes
  /// call this explicit lifetime half after resolving the same stable identity.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  func scheduleLifetimeReleaseIfUnobserved<Value>(
    for valueReference: Cog<Value>.Manual,
    in cogs: Cogs
  ) {
    let location = manualLocation(for: valueReference)
    scheduleLifetimeReleaseIfUnobserved(location.slot, in: cogs)
  }

  /// Renews grace after one transient synchronous-automatic demand.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  func scheduleLifetimeReleaseIfUnobserved<Value>(
    for valueReference: Cog<Value>,
    in cogs: Cogs
  ) {
    let location = automaticLocation(for: valueReference)
    scheduleLifetimeReleaseIfUnobserved(location.slot, in: cogs)
  }

  /// Renews grace after one transient async status demand.
  func scheduleLifetimeReleaseIfUnobserved<Value>(
    for valueReference: Cog<Value>.Async,
    in cogs: Cogs
  ) {
    let location = asyncLocation(
      descriptor: valueReference.descriptor,
      key: valueReference.key
    )
    scheduleLifetimeReleaseIfUnobserved(location.slot, in: cogs)
  }

  /// Reads one source through its lazily allocated Observation boundary.
  ///
  /// Resolving the value first installs the arena row; boundary access then
  /// records the exact public read without creating a graph dependency.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  func observedManualValue<Value>(for valueReference: Cog<Value>.Manual) -> Value {
    let location = manualLocation(for: valueReference)
    accessObservationBoundary(for: location.slot)
    return location.column.current(at: location.slot)
  }

  /// Settles and reads one automatic row through its Observation boundary.
  ///
  /// Settlement precedes registration so cold computation establishes the
  /// consumer's baseline before later completed turns can invalidate it.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  func observedAutomaticValue<Value>(for valueReference: Cog<Value>, in cogs: Cogs) -> Value {
    let location = automaticLocation(for: valueReference)
    settle(location.slot, in: cogs)
    accessObservationBoundary(for: location.slot)
    return location.column.current(at: location.slot)
  }

  /// Settles and reads one async status through its field-level UI boundary.
  func observedAsyncStatus<Value>(
    for valueReference: Cog<Value>.Async,
    in cogs: Cogs
  ) -> CogStatus<Value> {
    let location = asyncLocation(
      descriptor: valueReference.descriptor,
      key: valueReference.key
    )
    settle(location.slot, in: cogs)
    let boundary = ensureObservationBoundary(for: location.slot)
    return location.column.status(at: location.slot).observed(by: boundary)
  }

  /// Settles and returns one async status without installing a graph consumer.
  func asyncStatus<Value>(
    for valueReference: Cog<Value>.Async,
    in cogs: Cogs
  ) -> CogStatus<Value> {
    asyncStatus(
      descriptor: valueReference.descriptor,
      key: valueReference.key,
      in: cogs
    )
  }

  /// Settles an async descriptor-and-key status used by its value projection.
  func asyncStatus<Value>(
    descriptor: AsyncCogDescriptor<Value>,
    key: CogKey?,
    in cogs: Cogs
  ) -> CogStatus<Value> {
    let location = asyncLocation(descriptor: descriptor, key: key)
    settle(location.slot, in: cogs)
    return location.column.status(at: location.slot)
  }

  /// Forces one fresh arena async generation and returns its exact waiter.
  func refresh<Value>(_ valueReference: Cog<Value>.Async, in cogs: Cogs) -> CogRefresh<Value> {
    let location = asyncLocation(
      descriptor: valueReference.descriptor,
      key: valueReference.key
    )
    let waiter = CogRefreshWaiter<Value>()
    let refresh = CogRefresh(waiter: waiter)
    guard location.column.hasStatus(at: location.slot) else {
      settle(location.slot, in: cogs)
      location.column.register(
        waiter,
        for: location.column.generation(at: location.slot),
        at: location.slot
      )
      return refresh
    }

    cogs.withSystemTurn("\(renderedName(for: location.slot)) pending") { turn in
      guard self.stillStores(location.slot, descriptor: valueReference.descriptor) else {
        waiter.resolve(.released)
        return
      }
      let row = self.arena.index(of: location.slot)
      if let cycle = self.cyclePath(ifEnteringRow: row) {
        fatalError(cycle.message)
      }
      self.beginComputing(row)
      defer { self.endComputing(row) }
      self.recomputeAsync(
        descriptor: valueReference.descriptor,
        column: location.column,
        slot: location.slot,
        key: valueReference.key,
        publishingPendingIn: turn,
        refreshWaiter: waiter,
        in: cogs
      )
    }
    return refresh
  }

  /// Number of arena rows permanently pinned by a UI boundary.
  var observationBoundaryCount: Int {
    observationEntries.count
  }

  /// Whether an already-created descriptor-and-key row owns a UI boundary.
  ///
  /// The lookup is observational: an unknown identity returns `false` without
  /// allocating a row, descriptor record, value cell, or boundary.
  func hasObservationBoundary(for identity: CogStateIdentity) -> Bool {
    guard let slot = slots[identity], arena.contains(slot) else { return false }
    return arena.boundary[arena.index(of: slot)] != CogArenaStorage.noIndex
  }

  /// Descriptor lifetime restored by an installed manual arena row.
  ///
  /// This internal diagnostic lets infrastructure tests prove that the arena
  /// dispatch record, rather than only the declaration object, carries policy.
  func lifetimePolicy<Value>(for valueReference: Cog<Value>.Manual) -> CogStateLifetime {
    let location = manualLocation(for: valueReference)
    return descriptorRecord(forRow: arena.index(of: location.slot)).lifetime
  }

  /// Descriptor lifetime restored by an installed automatic arena row.
  func lifetimePolicy<Value>(for valueReference: Cog<Value>) -> CogStateLifetime {
    let location = automaticLocation(for: valueReference)
    return descriptorRecord(forRow: arena.index(of: location.slot)).lifetime
  }

  /// Durable reaction and UI owners of one installed manual arena row.
  func leaseCount<Value>(for valueReference: Cog<Value>.Manual) -> UInt32 {
    let location = manualLocation(for: valueReference)
    return arena.leaseCount[arena.index(of: location.slot)]
  }

  /// Durable reaction and UI owners of one installed automatic arena row.
  func leaseCount<Value>(for valueReference: Cog<Value>) -> UInt32 {
    let location = automaticLocation(for: valueReference)
    return arena.leaseCount[arena.index(of: location.slot)]
  }

  /// Settles and notifies the boundary roots changed in this arena revision.
  ///
  /// The count snapshot preserves the established baseline rule: a boundary
  /// created while another root settles joins the next flush and cannot receive
  /// a notice for a change that predates its first observed value.
  func flushObservationBoundaries(in cogs: Cogs) {
    guard propagation.hasChangedBoundaryRows else { return }

    // Notice order is boundary-creation order, and a row's boundary column is
    // its position in that order, so sorting on it restores what the registry
    // walk delivered for free. This sorts the changed set, which is the small
    // one; sorting was never the cost being removed.
    propagation.sortChangedBoundaryRows { arena.boundary[Int($0)] < arena.boundary[Int($1)] }

    // By index, and dropped afterwards, for the reason this method snapshots
    // its count: a notice can run a synchronous Observation handler that queues
    // another boundary, and that one belongs to the next flush.
    let queuedCount = propagation.changedBoundaryRowCount
    for position in 0..<queuedCount {
      let rawRow = propagation.changedBoundaryRow(at: position)
      let row = Int(rawRow)
      propagation.clearBoundaryNotice(row: rawRow)

      let entryIndex = arena.boundary[row]
      guard entryIndex != CogArenaStorage.noIndex else { continue }
      let index = Int(entryIndex)
      let slot = observationEntries[index].slot

      // Settle before the guard, because settling is what makes `changedAt`
      // current. The flag test comes first so a clean row — every pinned key on
      // an ordinary turn — never resolves its descriptor record at all.
      if needsSettlement(row), descriptorRecord(forRow: row).kind != .manual {
        settle(slot, in: cogs)
      }

      // The guard, then the entry and the record. `M9-03` put them in this
      // order when the walk still visited every boundary; a queued row can
      // still turn out unchanged — an equal recomputation settles clean — so
      // the order still earns its keep.
      let changedThisTurn = arena.changedAt[row] == revision
      #if DEBUG
      // A deferred seed change has to be consumed whether or not the row
      // changed this turn. Seeding invalidates, so a seeded row is queued.
      let changedBySeed = observationEntries[index].boundary.consumeDeferredChange()
      guard changedThisTurn || changedBySeed else { continue }
      recordHistoryState(event: .notice, slot: slot)
      #else
      guard changedThisTurn else { continue }
      #endif
      let entry = observationEntries[index]
      descriptorRecord(forRow: row).notifyObservation(entry.slot, entry.boundary)
    }

    propagation.dropFlushedBoundaryRows(queuedCount)
  }

  /// Releases one unobserved automatic row and allocates a replacement row.
  ///
  /// This package diagnostic drives PERF-05 through real descriptor lookup,
  /// typed-column removal, edge cleanup, identity removal, and arena reuse. The
  /// replacement is settled before the result returns, proving its new slot
  /// lifetime carries an independent value rather than stale column storage.
  func slotReuseSnapshot<ReleasedValue, ReplacementValue>(
    releasing releasedReference: Cog<ReleasedValue>,
    replacingWith replacementReference: Cog<ReplacementValue>,
    in cogs: Cogs
  ) -> CogArenaSlotReuseSnapshot {
    _ = automaticValue(for: releasedReference, in: cogs)
    let released = releaseAutomaticState(for: releasedReference)

    let replacement = automaticLocation(for: replacementReference)
    settle(replacement.slot, in: cogs)

    return CogArenaSlotReuseSnapshot(
      releasedIndex: released.index,
      releasedGeneration: released.generation,
      replacementIndex: replacement.slot.index,
      replacementGeneration: replacement.slot.generation
    )
  }

  /// Runs the PERF-05 reuse path and deliberately resolves the retired token.
  ///
  /// Called only inside a debug exit test. The final access must terminate with
  /// the arena's stale-generation diagnostic rather than reaching the new
  /// occupant that now owns the same integer row.
  func trapOnStaleSlotAccess<ReleasedValue, ReplacementValue>(
    releasing releasedReference: Cog<ReleasedValue>,
    replacingWith replacementReference: Cog<ReplacementValue>,
    in cogs: Cogs
  ) {
    _ = automaticValue(for: releasedReference, in: cogs)
    let released = releaseAutomaticState(for: releasedReference)

    let replacement = automaticLocation(for: replacementReference)
    settle(replacement.slot, in: cogs)

    _ = arena.index(of: released)
  }
}
