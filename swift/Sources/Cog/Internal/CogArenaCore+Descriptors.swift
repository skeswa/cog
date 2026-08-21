// MARK: - Descriptors and locations

/// Descriptor registration and descriptor-and-key location resolution.
///
/// This is the arena's sole transition from stable public identities to typed
/// columns and generated scalar slots. Keyless descriptor memos are validated
/// here against both context identity and slot generation before reuse.
extension CogArenaCore {
  /// Resolves one manual row and its typed descriptor column.
  ///
  /// Every keyless read, write, and lifetime renewal of a source arrives here,
  /// so this is one of two places where a steady turn pays for resolution. The
  /// memo on the declaration short-circuits three costs: the descriptor
  /// registry lookup, the checked downcast that restores `Value` from the
  /// record's erased column, and the identity lookup that finds the slot. The
  /// downcast is the expensive one — in unspecialized generic code it asks the
  /// runtime to instantiate ``CogArenaValueColumn`` metadata the caller was
  /// already handed.
  ///
  /// Two conditions make the memo sound, and both are checked here rather than
  /// maintained by invalidation hooks elsewhere. The context identity proves
  /// the memo was written by *this* graph, and identities are never reused.
  /// ``CogArenaStorage/contains(_:)`` then proves the memoized slot still
  /// names a live occupant: a released row always advances its generation
  /// before the index can be reused, so a state that has since been released —
  /// or replaced by another descriptor's state at the same index — fails this
  /// check and falls through to the ordinary path.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  func manualLocation<Value>(
    for valueReference: ManualCog<Value>
  ) -> (slot: CogArenaSlot, column: CogArenaValueColumn<Value>) {
    if valueReference.key == nil,
      let memo = valueReference.descriptor.memoizedArenaLocation(in: contextIdentity),
      arena.contains(memo.slot)
    {
      return memo
    }
    return resolvedManualLocation(for: valueReference)
  }

  /// Resolves or creates one manual row without consulting the memo.
  ///
  /// Split out so the memoized path above stays a straight line. A keyless
  /// resolution files its result on the declaration on the way out; a keyed
  /// one deliberately does not, because one declaration names a family of
  /// keyed states and a single-entry memo would thrash between them.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  func resolvedManualLocation<Value>(
    for valueReference: ManualCog<Value>
  ) -> (slot: CogArenaSlot, column: CogArenaValueColumn<Value>) {
    let descriptor = valueReference.descriptor
    let setup = manualRecord(for: descriptor)
    let identity = CogStateIdentity(
      descriptor: descriptor.identity,
      key: valueReference.key
    )

    let slot: CogArenaSlot
    if let existing = existingSlot(for: identity, record: setup.record) {
      slot = existing
    } else {
      slot = installSlot(for: identity, record: setup.record, key: valueReference.key)
      setup.column.insert(descriptor.startingValue(forKey: valueReference.key), at: slot)
    }

    if valueReference.key == nil {
      descriptor.memoizeArenaLocation(
        slot: slot,
        column: setup.column,
        in: contextIdentity
      )
    }
    return (slot, setup.column)
  }

  /// Resolves one automatic row and its typed descriptor column.
  ///
  /// The memo has the same two guards as ``manualLocation(for:)``, and the
  /// liveness one carries real weight here: a `whileObserved` automatic state is
  /// released when its grace expires, and the memo must not be able to hand
  /// back the row it used to own.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  func automaticLocation<Value>(
    for valueReference: Cog<Value>
  ) -> (slot: CogArenaSlot, column: CogArenaValueColumn<Value>) {
    if valueReference.key == nil,
      let memo = valueReference.descriptor.memoizedArenaLocation(in: contextIdentity),
      arena.contains(memo.slot)
    {
      return memo
    }
    return resolvedAutomaticLocation(for: valueReference)
  }

  /// Resolves or creates one cold automatic row without consulting the memo.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  func resolvedAutomaticLocation<Value>(
    for valueReference: Cog<Value>
  ) -> (slot: CogArenaSlot, column: CogArenaValueColumn<Value>) {
    let descriptor = valueReference.descriptor
    let setup = automaticRecord(for: descriptor)
    let identity = CogStateIdentity(
      descriptor: descriptor.identity,
      key: valueReference.key
    )

    let slot: CogArenaSlot
    if let existing = existingSlot(for: identity, record: setup.record) {
      slot = existing
    } else {
      slot = installSlot(for: identity, record: setup.record, key: valueReference.key)
      arena.flags[arena.index(of: slot)].insert(.dirty)
    }

    if valueReference.key == nil {
      descriptor.memoizeArenaLocation(
        slot: slot,
        column: setup.column,
        in: contextIdentity
      )
    }
    return (slot, setup.column)
  }

  /// Resolves or creates one cold async status row and its descriptor sidecars.
  func asyncLocation<Value>(
    descriptor: AsyncCogDescriptor<Value>,
    key: CogKey?
  ) -> (slot: CogArenaSlot, column: CogArenaAsyncColumn<Value>) {
    let setup = asyncRecord(for: descriptor)
    let identity = CogStateIdentity(descriptor: descriptor.identity, key: key)
    if let slot = existingSlot(for: identity, record: setup.record) {
      return (slot, setup.column)
    }

    let slot = installSlot(for: identity, record: setup.record, key: key)
    setup.column.install(at: slot)
    arena.flags[arena.index(of: slot)].insert(.dirty)
    return (slot, setup.column)
  }

  /// Restores the manual descriptor's concrete column through checked setup.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  func manualRecord<Value>(
    for descriptor: ManualCogDescriptor<Value>
  ) -> (record: CogArenaDescriptorRecord, column: CogArenaValueColumn<Value>) {
    if let record = recordsByIdentity[descriptor.identity] {
      guard record.kind == .manual,
        let column = record.column as? CogArenaValueColumn<Value>
      else {
        fatalError("Cog restored a manual arena descriptor with the wrong value type.")
      }
      return (record, column)
    }

    let column = CogArenaValueColumn<Value>(
      in: arena,
      equals: { descriptor.valuesAreEqual($0, $1) }
    )
    let record = makeRecord(
      identity: descriptor.identity,
      label: descriptor.label,
      kind: .manual,
      lifetime: descriptor.lifetime,
      column: column,
      asyncColumn: nil,
      publishSource: { slot, revision, propagation in
        column.publishSource(at: slot, revision: revision, propagatingWith: propagation)
      },
      recompute: nil,
      notifyObservation: { _, boundary in boundary.notifyValueChange() },
      removeValue: { slot in column.remove(at: slot) },
      prepareForContextTeardown: {},
      forgetMemoizedLocation: { context in
        descriptor.forgetMemoizedArenaLocation(in: context)
      }
    )
    return (record, column)
  }

  /// Restores the automatic descriptor's concrete column and recompute function.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  func automaticRecord<Value>(
    for descriptor: AutomaticCogDescriptor<Value>
  ) -> (record: CogArenaDescriptorRecord, column: CogArenaValueColumn<Value>) {
    if let record = recordsByIdentity[descriptor.identity] {
      guard record.kind == .automatic,
        let column = record.column as? CogArenaValueColumn<Value>
      else {
        fatalError("Cog restored an automatic arena descriptor with the wrong value type.")
      }
      return (record, column)
    }

    let column = CogArenaValueColumn<Value>(
      in: arena,
      equals: { descriptor.valuesAreEqual($0, $1) }
    )
    let record = makeRecord(
      identity: descriptor.identity,
      label: descriptor.label,
      kind: .automatic,
      lifetime: descriptor.lifetime,
      column: column,
      asyncColumn: nil,
      publishSource: nil,
      recompute: { core, cogs, slot, key in
        core.recompute(descriptor: descriptor, column: column, slot: slot, key: key, in: cogs)
      },
      notifyObservation: { _, boundary in boundary.notifyValueChange() },
      removeValue: { slot in column.remove(at: slot) },
      prepareForContextTeardown: {},
      forgetMemoizedLocation: { context in
        descriptor.forgetMemoizedArenaLocation(in: context)
      }
    )
    return (record, column)
  }

  /// Restores one async descriptor's concrete status and task sidecars.
  func asyncRecord<Value>(
    for descriptor: AsyncCogDescriptor<Value>
  ) -> (record: CogArenaDescriptorRecord, column: CogArenaAsyncColumn<Value>) {
    if let record = recordsByIdentity[descriptor.identity] {
      guard record.kind == .async,
        let column = record.asyncColumn as? CogArenaAsyncColumn<Value>
      else {
        fatalError("Cog restored an async arena descriptor with the wrong value type.")
      }
      return (record, column)
    }

    let column = CogArenaAsyncColumn(in: arena, descriptor: descriptor)
    let record = makeRecord(
      identity: descriptor.identity,
      label: descriptor.label,
      kind: .async,
      lifetime: descriptor.lifetime,
      column: column.statuses,
      asyncColumn: column,
      publishSource: { slot, revision, propagation in
        column.publishPendingStatus(
          at: slot,
          revision: revision,
          propagatingWith: propagation
        )
      },
      recompute: { core, cogs, slot, key in
        core.recomputeAsync(
          descriptor: descriptor,
          column: column,
          slot: slot,
          key: key,
          in: cogs
        )
      },
      notifyObservation: { slot, boundary in
        column.notifyObservation(at: slot, through: boundary)
      },
      removeValue: { slot in column.remove(at: slot) },
      prepareForContextTeardown: { column.prepareForContextTeardown() },
      // Async declarations memoize nothing: their statuses are not on the
      // steady-turn path this memo exists for, and adding a second memo shape
      // would widen the invalidation surface for no measured gain.
      forgetMemoizedLocation: { _ in }
    )
    return (record, column)
  }

  /// Registers one descriptor and returns its dense dispatch record.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  func makeRecord(
    identity: ObjectIdentifier,
    label: CogLabel,
    kind: CogArenaDescriptorKind,
    lifetime: CogStateLifetime,
    column: AnyObject,
    asyncColumn: AnyObject?,
    publishSource: (@MainActor (CogArenaSlot, UInt32, CogArenaDirtyPropagation) -> Bool)?,
    recompute: (@MainActor (CogArenaCore, Cogs, CogArenaSlot, CogKey?) -> Void)?,
    notifyObservation: @escaping @MainActor (CogArenaSlot, CogObservationBoundary) -> Void,
    removeValue: @escaping @MainActor (CogArenaSlot) -> Void,
    prepareForContextTeardown: @escaping @MainActor () -> Void,
    forgetMemoizedLocation: @escaping @MainActor (UInt64) -> Void
  ) -> CogArenaDescriptorRecord {
    guard records.count <= Int(Int32.max) else {
      fatalError("Cog exhausted its Int32 arena descriptor index space.")
    }
    let record = CogArenaDescriptorRecord(
      identity: identity,
      label: label,
      index: Int32(records.count),
      kind: kind,
      lifetime: lifetime,
      column: column,
      asyncColumn: asyncColumn,
      publishSource: publishSource,
      recompute: recompute,
      notifyObservation: notifyObservation,
      removeValue: removeValue,
      prepareForContextTeardown: prepareForContextTeardown,
      forgetMemoizedLocation: forgetMemoizedLocation
    )
    recordsByIdentity[identity] = record
    records.append(.passUnretained(record))
    return record
  }

  /// Returns the exact live slot already filed for `identity`, when present.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  func existingSlot(
    for identity: CogStateIdentity,
    record: CogArenaDescriptorRecord
  ) -> CogArenaSlot? {
    guard let slot = slots[identity] else { return nil }
    let row = arena.index(of: slot)
    guard arena.descriptor[row] == record.index else {
      fatalError("Cog found an arena state filed under another descriptor record.")
    }
    return slot
  }

  /// Whether one exact slot still belongs to the supplied async descriptor.
  ///
  /// Work completions combine this context identity check with the descriptor
  /// column's UInt64 generation, so cancellation and scalar slot reuse are both
  /// advisory rather than correctness boundaries.
  func stillStores<Value>(
    _ slot: CogArenaSlot,
    descriptor: AsyncCogDescriptor<Value>
  ) -> Bool {
    guard arena.contains(slot) else { return false }
    let row = Int(slot.index)
    let record = descriptorRecord(forRow: row)
    guard record.identity == descriptor.identity else { return false }
    let identity = CogStateIdentity(descriptor: descriptor.identity, key: record.key(at: row))
    return slots[identity] == slot
  }

  /// Renders one live row with the diagnostic naming rule shared by task turns.
  func renderedName(for slot: CogArenaSlot) -> String {
    let row = arena.index(of: slot)
    let record = descriptorRecord(forRow: row)
    guard let key = record.key(at: row) else { return "\(record.label)" }
    return "\(record.label)[\(key.erased.base)]"
  }

  /// Allocates and files one row for a descriptor-and-key identity.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  func installSlot(
    for identity: CogStateIdentity,
    record: CogArenaDescriptorRecord,
    key: CogKey?
  ) -> CogArenaSlot {
    let slot = arena.allocate()
    let row = arena.index(of: slot)
    arena.descriptor[row] = record.index
    resetLifetimeEntry(at: row)
    record.install(key: key, at: row)
    slots[identity] = slot
    return slot
  }

  /// Removes one settled, unobserved automatic state for the slot-reuse probe.
  ///
  /// Production grace expiry reaches the same erased release sequence. This
  /// typed entry only proves that the diagnostic names the expected descriptor
  /// before it deliberately returns the retired token to its caller.
  func releaseAutomaticState<Value>(for valueReference: Cog<Value>) -> CogArenaSlot {
    let identity = CogStateIdentity(
      descriptor: valueReference.descriptor.identity,
      key: valueReference.key
    )
    guard let slot = slots[identity] else {
      fatalError("Cog tried to release an arena automatic state that was not installed.")
    }

    let setup = automaticRecord(for: valueReference.descriptor)
    let row = arena.index(of: slot)
    guard arena.descriptor[row] == setup.record.index else {
      fatalError("Cog tried to release an arena row through another descriptor.")
    }
    var ignoredDependencies: ContiguousArray<CogArenaSlot> = []
    releaseValueState(slot, appendingDependenciesTo: &ignoredDependencies)
    return slot
  }
}
