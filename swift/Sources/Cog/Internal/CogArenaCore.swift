#if COG_CORE_ARENA
/// Production role of one descriptor in the arena vertical slice.
private nonisolated enum CogArenaDescriptorKind {
  /// A source whose typed column owns current and pending values.
  case manual

  /// A synchronous selector whose typed column begins without a value.
  case derived
}

/// Type-erased setup record retained once per descriptor by an arena context.
///
/// Normal typed access downcasts `column` at the descriptor boundary. Indexed
/// graph walks instead use the scalar descriptor index on each row and invoke
/// one descriptor-level function, never a per-state closure or existential.
@MainActor
private final class CogArenaDescriptorRecord {
  /// Dense context-local dispatch index stored on every row of this descriptor.
  let index: Int32

  /// Whether rows are manual sources or synchronous derived values.
  let kind: CogArenaDescriptorKind

  /// Concrete ``CogArenaValueColumn`` restored by checked generic setup.
  let column: AnyObject

  /// Publishes a pending source value, or `nil` for derived descriptors.
  let commitSource: (@MainActor (CogArenaSlot, UInt32, CogArenaDirtyPropagation) -> Bool)?

  /// Reruns one derived row, or `nil` for manual descriptors.
  let recompute: (@MainActor (CogArenaCore, Cogs, CogArenaSlot, CogKey?) -> Void)?

  /// Erased selector key by global arena row.
  ///
  /// The current vertical slice exercises keyless rows. Keeping keys on the
  /// descriptor record already avoids a graph-wide key table; later keyed
  /// integration can specialize this storage without changing row dispatch.
  private var keys: ContiguousArray<CogKey?> = []

  /// Creates one immutable descriptor dispatch record.
  init(
    index: Int32,
    kind: CogArenaDescriptorKind,
    column: AnyObject,
    commitSource: (@MainActor (CogArenaSlot, UInt32, CogArenaDirtyPropagation) -> Bool)?,
    recompute: (@MainActor (CogArenaCore, Cogs, CogArenaSlot, CogKey?) -> Void)?
  ) {
    self.index = index
    self.kind = kind
    self.column = column
    self.commitSource = commitSource
    self.recompute = recompute
  }

  /// Installs the selector key for one newly allocated row.
  func install(key: CogKey?, at row: Int) {
    if row >= keys.count {
      keys.append(contentsOf: repeatElement(.none, count: row + 1 - keys.count))
    }
    keys[row] = key
  }

  /// Returns the key belonging to one row dispatched through this record.
  func key(at row: Int) -> CogKey? {
    guard row < keys.count else {
      fatalError("Cog found an arena descriptor row without key storage.")
    }
    return keys[row]
  }
}

/// Phase of one scalar frame in the iterative pull walk.
private nonisolated enum CogArenaPullPhase {
  /// Schedule stale dependencies before the consumer.
  case enter

  /// Decide whether the now-current dependencies require a selector run.
  case exit
}

/// One row-only frame retained in the context pull buffer.
private nonisolated struct CogArenaPullFrame {
  /// Arena row to settle.
  let row: Int32

  /// Whether this frame enters or exits the row.
  let phase: CogArenaPullPhase
}

/// Cursor state for one selector currently capturing dependency reads.
private nonisolated struct CogArenaDependencyCapture {
  /// Derived row receiving every read in this scope.
  let consumer: CogArenaSlot

  /// Next prior dependency available for static-prefix reuse.
  var cursor: CogEdgeIndex

  /// Last dependency accepted in selector read order.
  var previous: CogEdgeIndex
}

/// Context-owned data-oriented graph machinery behind the arena selector.
///
/// Stable public references still name descriptors and keys. This context maps
/// those names to generated slots, while hot propagation and settlement carry
/// only integer rows. Descriptor records own typed columns and one dispatch
/// function each; state rows own no classes or closures.
@MainActor
internal final class CogArenaCore {
  /// Scalar state rows shared by every descriptor column.
  let arena: CogArenaStorage

  /// Baseline indexed edge candidate.
  let edges: CogLinkedEdgePool

  /// Reused iterative push engine over `edges`.
  let propagation: CogArenaDirtyPropagation

  /// Latest graph revision assigned by the enclosing context turn.
  private(set) var revision: UInt32 = 0

  /// Stable descriptor-and-key names resolved to exact slot lifetimes.
  private var slots: [CogStateIdentity: CogArenaSlot] = [:]

  /// Strong registry retaining each descriptor record exactly once.
  private var recordsByIdentity: [ObjectIdentifier: CogArenaDescriptorRecord] = [:]

  /// Integer-indexed unretained view of `recordsByIdentity` for graph walks.
  private var records: ContiguousArray<Unmanaged<CogArenaDescriptorRecord>> = []

  /// Reused enter/exit storage for iterative warm settlement.
  private var pullFrames: ContiguousArray<CogArenaPullFrame> = []

  /// Nested selector scopes, outermost first.
  private var captures: ContiguousArray<CogArenaDependencyCapture> = []

  /// Creates one empty arena graph and binds its pool propagator.
  init() {
    let arena = CogArenaStorage()
    let edges = CogLinkedEdgePool()
    self.arena = arena
    self.edges = edges
    self.propagation = CogArenaDirtyPropagation(arena: arena, edges: edges)
  }

  /// Advances the compact arena revision once for an enclosing context turn.
  func advanceRevision() {
    guard revision < UInt32.max else {
      fatalError("Cog exhausted its UInt32 arena revision space.")
    }
    revision += 1
  }

  #if COG_CORE_ARENA
  /// Stages one typed source and registers its row once with the active turn.
  func writerStage<Value>(
    _ valueReference: ManualCog<Value>,
    value: Value,
    in turn: CogTurn
  ) {
    let location = manualLocation(for: valueReference)
    location.column.stage(value, at: location.slot)

    let row = arena.index(of: location.slot)
    guard !arena.flags[row].contains(.touched) else { return }
    arena.flags[row].insert(.touched)
    turn.touchArenaSource(location.slot)
  }

  /// Publishes every source row touched by one arena turn.
  func flushPendingSources(_ touchedSources: ContiguousArray<CogArenaSlot>) {
    for slot in touchedSources {
      let row = arena.index(of: slot)
      guard arena.flags[row].contains(.touched) else {
        fatalError("Cog found an arena turn entry whose source was not touched.")
      }
      let record = descriptorRecord(forRow: row)
      guard record.kind == .manual, let commit = record.commitSource else {
        fatalError("Cog tried to flush a non-source arena row as pending state.")
      }

      _ = commit(slot, revision, propagation)
      arena.flags[row].remove(.touched)
    }
  }
  #endif

  /// Reads the pending overlay or current value of one source for a writer.
  func writerValue<Value>(for valueReference: ManualCog<Value>) -> Value {
    let location = manualLocation(for: valueReference)
    return location.column.writerValue(at: location.slot)
  }

  /// Reads one source without recording a dependency.
  func manualValue<Value>(for valueReference: ManualCog<Value>) -> Value {
    let location = manualLocation(for: valueReference)
    return location.column.current(at: location.slot)
  }

  /// Pulls one derived value current without recording a dependency.
  func derivedValue<Value>(for valueReference: Cog<Value>, in cogs: Cogs) -> Value {
    let location = derivedLocation(for: valueReference)
    settle(location.slot, in: cogs)
    return location.column.current(at: location.slot)
  }

  /// Reads and records one manual dependency for the active arena selector.
  func read<Value>(
    _ valueReference: ManualCog<Value>,
    for consumer: CogArenaSlot
  ) -> Value {
    requireTracking(consumer)
    let producer = manualLocation(for: valueReference)
    recordDependency(from: consumer, on: producer.slot)
    return producer.column.current(at: producer.slot)
  }

  /// Pulls, reads, and records one derived dependency for the active selector.
  func read<Value>(
    _ valueReference: Cog<Value>,
    for consumer: CogArenaSlot,
    in cogs: Cogs
  ) -> Value {
    requireTracking(consumer)
    let producer = derivedLocation(for: valueReference)
    settle(producer.slot, in: cogs)
    requireTracking(consumer)
    recordDependency(from: consumer, on: producer.slot)
    return producer.column.current(at: producer.slot)
  }

  /// Previous completed value of the active derived selector, if one exists.
  func previousValue<Value>(for consumer: CogArenaSlot, as: Value.Type) -> Value? {
    requireTracking(consumer)
    let row = arena.index(of: consumer)
    let record = descriptorRecord(forRow: row)
    guard let column = record.column as? CogArenaValueColumn<Value> else {
      fatalError("Cog restored an arena selector through the wrong typed value column.")
    }
    return column.storedValue(at: consumer)
  }

  /// Requires `consumer` to own the innermost active dependency capture.
  func requireTracking(_ consumer: CogArenaSlot) {
    guard captures.last?.consumer == consumer else {
      fatalError("A Cog reader is valid only inside the selector run that handed it out.")
    }
  }

  /// Resolves or creates one manual row and its typed descriptor column.
  private func manualLocation<Value>(
    for valueReference: ManualCog<Value>
  ) -> (slot: CogArenaSlot, column: CogArenaValueColumn<Value>) {
    let setup = manualRecord(for: valueReference.descriptor)
    let identity = CogStateIdentity(
      descriptor: valueReference.descriptor.identity,
      key: valueReference.key
    )
    if let slot = existingSlot(for: identity, record: setup.record) {
      return (slot, setup.column)
    }

    let slot = installSlot(for: identity, record: setup.record, key: valueReference.key)
    setup.column.insert(
      valueReference.descriptor.startingValue(forKey: valueReference.key), at: slot)
    return (slot, setup.column)
  }

  /// Resolves or creates one cold derived row and its typed descriptor column.
  private func derivedLocation<Value>(
    for valueReference: Cog<Value>
  ) -> (slot: CogArenaSlot, column: CogArenaValueColumn<Value>) {
    let setup = derivedRecord(for: valueReference.descriptor)
    let identity = CogStateIdentity(
      descriptor: valueReference.descriptor.identity,
      key: valueReference.key
    )
    if let slot = existingSlot(for: identity, record: setup.record) {
      return (slot, setup.column)
    }

    let slot = installSlot(for: identity, record: setup.record, key: valueReference.key)
    arena.flags[arena.index(of: slot)].insert(.dirty)
    return (slot, setup.column)
  }

  /// Restores the manual descriptor's concrete column through checked setup.
  private func manualRecord<Value>(
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
      kind: .manual,
      column: column,
      commitSource: { slot, revision, propagation in
        column.commitSource(at: slot, revision: revision, propagatingWith: propagation)
      },
      recompute: nil
    )
    return (record, column)
  }

  /// Restores the derived descriptor's concrete column and recompute function.
  private func derivedRecord<Value>(
    for descriptor: DerivedCogDescriptor<Value>
  ) -> (record: CogArenaDescriptorRecord, column: CogArenaValueColumn<Value>) {
    if let record = recordsByIdentity[descriptor.identity] {
      guard record.kind == .derived,
        let column = record.column as? CogArenaValueColumn<Value>
      else {
        fatalError("Cog restored a derived arena descriptor with the wrong value type.")
      }
      return (record, column)
    }

    let column = CogArenaValueColumn<Value>(
      in: arena,
      equals: { descriptor.valuesAreEqual($0, $1) }
    )
    let record = makeRecord(
      identity: descriptor.identity,
      kind: .derived,
      column: column,
      commitSource: nil,
      recompute: { core, cogs, slot, key in
        core.recompute(descriptor: descriptor, column: column, slot: slot, key: key, in: cogs)
      }
    )
    return (record, column)
  }

  /// Registers one descriptor and returns its dense dispatch record.
  private func makeRecord(
    identity: ObjectIdentifier,
    kind: CogArenaDescriptorKind,
    column: AnyObject,
    commitSource: (@MainActor (CogArenaSlot, UInt32, CogArenaDirtyPropagation) -> Bool)?,
    recompute: (@MainActor (CogArenaCore, Cogs, CogArenaSlot, CogKey?) -> Void)?
  ) -> CogArenaDescriptorRecord {
    guard records.count <= Int(Int32.max) else {
      fatalError("Cog exhausted its Int32 arena descriptor index space.")
    }
    let record = CogArenaDescriptorRecord(
      index: Int32(records.count),
      kind: kind,
      column: column,
      commitSource: commitSource,
      recompute: recompute
    )
    recordsByIdentity[identity] = record
    records.append(.passUnretained(record))
    return record
  }

  /// Returns the exact live slot already filed for `identity`, when present.
  private func existingSlot(
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

  /// Allocates and files one row for a descriptor-and-key identity.
  private func installSlot(
    for identity: CogStateIdentity,
    record: CogArenaDescriptorRecord,
    key: CogKey?
  ) -> CogArenaSlot {
    let slot = arena.allocate()
    let row = arena.index(of: slot)
    arena.descriptor[row] = record.index
    record.install(key: key, at: row)
    slots[identity] = slot
    return slot
  }

  /// Resolves one row's descriptor record without retaining it in the walk.
  private func descriptorRecord(forRow row: Int) -> CogArenaDescriptorRecord {
    let descriptorIndex = arena.descriptor[row]
    guard descriptorIndex >= 0, Int(descriptorIndex) < records.count else {
      fatalError("Cog found a live arena row without descriptor dispatch.")
    }
    return records[Int(descriptorIndex)].takeUnretainedValue()
  }

  /// Pulls one derived row current through reusable scalar enter/exit frames.
  private func settle(_ root: CogArenaSlot, in cogs: Cogs) {
    let rootRow = arena.index(of: root)
    let boundary = pullFrames.count
    pullFrames.append(CogArenaPullFrame(row: Int32(rootRow), phase: .enter))

    while pullFrames.count > boundary, let frame = pullFrames.popLast() {
      let row = liveRow(frame.row)
      switch frame.phase {
      case .enter:
        guard needsSettlement(row) else { continue }
        let record = descriptorRecord(forRow: row)
        guard record.kind == .derived else {
          fatalError("Cog found an invalid manual source in the arena pull walk.")
        }

        pullFrames.append(CogArenaPullFrame(row: frame.row, phase: .exit))
        appendDependencies(of: frame.row)

      case .exit:
        let record = descriptorRecord(forRow: row)
        let mustRecompute = arena.flags[row].contains(.dirty) || dependencyChanged(for: frame.row)
        if mustRecompute {
          guard let recompute = record.recompute else {
            fatalError("Cog found a derived arena row without a recompute function.")
          }
          let slot = CogArenaSlot(index: frame.row, generation: arena.generation[row])
          recompute(self, cogs, slot, record.key(at: row))
        } else {
          arena.checkedAt[row] = revision
          arena.flags[row].remove(.check)
          arena.flags[row].remove(.dirty)
        }
      }
    }
  }

  /// Appends stale producers of `consumerRow` for settlement before its exit.
  private func appendDependencies(of consumerRow: Int32) {
    var cursor = arena.deps[Int(consumerRow)]
    while cursor != .none {
      let edge = edges.edge(at: cursor)
      guard edge.sub == consumerRow else {
        fatalError("Cog found another consumer's edge in an arena dependency list.")
      }
      let producerRow = liveRow(edge.dep)
      if needsSettlement(producerRow) {
        pullFrames.append(CogArenaPullFrame(row: edge.dep, phase: .enter))
      }
      cursor = edge.nextDep
    }
  }

  /// Whether any dependency changed after this consumer was last current.
  private func dependencyChanged(for consumerRow: Int32) -> Bool {
    let checkedAt = arena.checkedAt[Int(consumerRow)]
    var cursor = arena.deps[Int(consumerRow)]
    while cursor != .none {
      let edge = edges.edge(at: cursor)
      guard edge.sub == consumerRow else {
        fatalError("Cog found another consumer's edge in an arena dependency list.")
      }
      if arena.changedAt[liveRow(edge.dep)] > checkedAt {
        return true
      }
      cursor = edge.nextDep
    }
    return false
  }

  /// Runs one typed selector and publishes or backdates its completed result.
  private func recompute<Value>(
    descriptor: DerivedCogDescriptor<Value>,
    column: CogArenaValueColumn<Value>,
    slot: CogArenaSlot,
    key: CogKey?,
    in cogs: Cogs
  ) {
    let previousValue = column.storedValue(at: slot)
    let value = withDependencyCapture(for: slot) {
      descriptor.compute(Reader(cogs: cogs, arenaState: slot), key: key)
    }

    let changed: Bool
    if case .some = previousValue {
      column.stage(value, at: slot)
      changed = column.commit(at: slot)
    } else {
      column.insert(value, at: slot)
      changed = true
    }

    let row = arena.index(of: slot)
    if changed {
      arena.changedAt[row] = revision
    }
    arena.checkedAt[row] = revision
    arena.flags[row].remove(.check)
    arena.flags[row].remove(.dirty)
  }

  /// Runs one selector with a nested static-prefix dependency cursor.
  private func withDependencyCapture<Result>(
    for consumer: CogArenaSlot,
    _ body: () -> Result
  ) -> Result {
    let row = arena.index(of: consumer)
    captures.append(
      CogArenaDependencyCapture(
        consumer: consumer,
        cursor: arena.deps[row],
        previous: .none
      )
    )
    defer {
      guard let finished = captures.popLast(), finished.consumer == consumer else {
        fatalError("Cog finished arena dependency capture out of order.")
      }
      if finished.cursor != .none {
        edges.removeDependencySuffix(
          of: consumer,
          after: finished.previous,
          in: arena
        )
      }
    }
    return body()
  }

  /// Reuses the next matching edge or appends one cold static dependency.
  private func recordDependency(from consumer: CogArenaSlot, on producer: CogArenaSlot) {
    guard let captureIndex = captures.indices.last else {
      fatalError("Cog recorded an arena dependency outside selector capture.")
    }
    var capture = captures[captureIndex]
    guard capture.consumer == consumer else {
      fatalError("Cog recorded an arena dependency for a non-active selector.")
    }

    if capture.cursor != .none {
      let edge = edges.edge(at: capture.cursor)
      if edge.dep == producer.index, edge.sub == consumer.index {
        edges.updateVersion(
          of: capture.cursor,
          to: arena.changedAt[arena.index(of: producer)]
        )
        capture.previous = capture.cursor
        capture.cursor = edge.nextDep
        captures[captureIndex] = capture
        return
      }

      edges.removeDependencySuffix(
        of: consumer,
        after: capture.previous,
        in: arena
      )
      capture.cursor = .none
    }

    let added = edges.add(
      producer: producer,
      consumer: consumer,
      after: capture.previous,
      version: arena.changedAt[arena.index(of: producer)],
      in: arena
    )
    capture.previous = added

    captures[captureIndex] = capture
  }

  /// Whether one row carries CHECK or DIRTY work.
  private func needsSettlement(_ row: Int) -> Bool {
    arena.flags[row].contains(.check) || arena.flags[row].contains(.dirty)
  }

  /// Validates one raw edge row and returns its native array index.
  private func liveRow(_ rawRow: Int32) -> Int {
    guard rawRow >= 0 else {
      fatalError("Cog found a negative arena state row in graph topology.")
    }
    let row = Int(rawRow)
    guard row < arena.rowCount, arena.flags[row].contains(.occupied) else {
      fatalError("Cog found a released arena state row in graph topology.")
    }
    return row
  }
}
#endif
