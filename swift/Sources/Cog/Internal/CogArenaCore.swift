#if COG_CORE_ARENA
/// Primitive result of the package-only arena slot-reuse probe.
///
/// `CogTesting` maps this internal representation to its public diagnostic
/// value. Production API never exposes arena indices or generations, so a
/// normal value reference remains a stable descriptor-and-key name.
package nonisolated struct CogArenaSlotReuseSnapshot: Sendable {
  /// Row returned to the allocator by the released derived state.
  package let releasedIndex: Int32

  /// Generation carried by the released state's now-stale token.
  package let releasedGeneration: UInt16

  /// Row allocated to the replacement derived state.
  package let replacementIndex: Int32

  /// Generation carried by the replacement's live token.
  package let replacementGeneration: UInt16
}

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
  /// Process identity of the public declaration represented by this record.
  let identity: ObjectIdentifier

  /// Human-readable declaration label used only when rendering diagnostics.
  let label: CogLabel

  /// Dense context-local dispatch index stored on every row of this descriptor.
  let index: Int32

  /// Whether rows are manual sources or synchronous derived values.
  let kind: CogArenaDescriptorKind

  /// Retention policy shared by every row belonging to this descriptor.
  ///
  /// Keeping it on the descriptor dispatch record avoids repeating an enum in
  /// every scalar row. Only the cold lease and release paths load it.
  let lifetime: CogStateLifetime

  /// Concrete ``CogArenaValueColumn`` restored by checked generic setup.
  let column: AnyObject

  /// Publishes a pending source value, or `nil` for derived descriptors.
  let commitSource: (@MainActor (CogArenaSlot, UInt32, CogSelectedArenaDirtyPropagation) -> Bool)?

  /// Reruns one derived row, or `nil` for manual descriptors.
  let recompute: (@MainActor (CogArenaCore, Cogs, CogArenaSlot, CogKey?) -> Void)?

  /// Clears this descriptor's typed value cell before a scalar row is reused.
  ///
  /// Lifetime expiry starts from an erased slot, so release dispatches once at
  /// the descriptor boundary instead of storing a closure or existential on
  /// every arena row.
  let removeValue: @MainActor (CogArenaSlot) -> Void

  /// Erased selector key by global arena row.
  ///
  /// The current vertical slice exercises keyless rows. Keeping keys on the
  /// descriptor record already avoids a graph-wide key table; later keyed
  /// integration can specialize this storage without changing row dispatch.
  private var keys: ContiguousArray<CogKey?> = []

  /// Creates one immutable descriptor dispatch record.
  init(
    identity: ObjectIdentifier,
    label: CogLabel,
    index: Int32,
    kind: CogArenaDescriptorKind,
    lifetime: CogStateLifetime,
    column: AnyObject,
    commitSource: (@MainActor (CogArenaSlot, UInt32, CogSelectedArenaDirtyPropagation) -> Bool)?,
    recompute: (@MainActor (CogArenaCore, Cogs, CogArenaSlot, CogKey?) -> Void)?,
    removeValue: @escaping @MainActor (CogArenaSlot) -> Void
  ) {
    self.identity = identity
    self.label = label
    self.index = index
    self.kind = kind
    self.lifetime = lifetime
    self.column = column
    self.commitSource = commitSource
    self.recompute = recompute
    self.removeValue = removeValue
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

  /// Releases the erased key retained for a departing row.
  ///
  /// The descriptor record itself remains registered for the context, but a
  /// removed keyed value must not stay alive merely because its scalar row may
  /// later be occupied by another descriptor.
  func removeKey(at row: Int) {
    guard row < keys.count else {
      fatalError("Cog tried to remove an arena descriptor row without key storage.")
    }
    keys[row] = nil
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
  var cursor: CogSelectedArenaEdgeStorage.Cursor

  /// Last dependency accepted in selector read order.
  var previous: CogSelectedArenaEdgeStorage.Cursor
}

/// One lazily created Observation boundary pinned to an exact slot lifetime.
///
/// The scalar arena row stores this entry's index. Keeping the boundary object
/// and generation-bearing slot together lets the cold UI flush validate that
/// a permanent boundary was never detached from its original state.
private nonisolated struct CogArenaObservationEntry {
  /// State lifetime whose UI reads and changes this boundary represents.
  let slot: CogArenaSlot

  /// Registrar-backed object exposed only through phantom Observation reads.
  let boundary: CogObservationBoundary
}

/// Cold grace-period ownership for one arena row.
///
/// The exact arena slot generation rejects a sleeper from a former occupant;
/// this independent generation rejects a cancelled or renewed sleeper for the
/// same occupant. Keeping the task out of ``CogArenaStorage`` prevents lifetime
/// policy from adding a reference-valued column to hot graph walks.
private struct CogArenaLifetimeEntry {
  /// Monotonic token advanced before cancellation or replacement.
  var generation: UInt64 = 0

  /// Generation whose deadline has not yet completed, if any.
  var pendingGeneration: UInt64?

  /// Sole grace sleeper owned by this exact row occupant.
  var task: Task<Void, Never>?
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

  /// Concrete indexed edge representation selected for this build.
  let edges: CogSelectedArenaEdgeStorage

  /// Reused iterative push engine over `edges`.
  let propagation: CogSelectedArenaDirtyPropagation

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

  /// Reused roots copied from one reaction terminal before its dependencies settle.
  ///
  /// Pulling a producer may recapture edges elsewhere in the shared pool. The
  /// snapshot keeps reaction traversal independent of those mutations without
  /// allocating again after reaching its high-water mark.
  private var reactionPullRoots: ContiguousArray<CogArenaSlot> = []

  /// Nested selector scopes, outermost first.
  private var captures: ContiguousArray<CogArenaDependencyCapture> = []

  /// UI-read roots in boundary creation order.
  ///
  /// Interior and unread rows never enter this table. Entries are permanent in
  /// v1, making the boundary itself the durable UI lease while the row's scalar
  /// `boundary` column keeps hot storage to one optional index.
  private var observationEntries: ContiguousArray<CogArenaObservationEntry> = []

  /// Grace metadata indexed by scalar row for installed value states.
  ///
  /// Reaction-only rows need no entry. The array grows lazily when a value row
  /// is installed and entries reset before a released index changes identity.
  private var lifetimeEntries: ContiguousArray<CogArenaLifetimeEntry> = []

  #if DEBUG
  /// Fixed-capacity integer history owned by the arena context.
  ///
  /// This property and every use compile out of release. Arena state events
  /// enter it by descriptor index; labels resolve only through `historySnapshot`.
  private var historyLog = CogArenaHistoryLog()
  #endif

  /// Derived rows whose settlement has entered but not completed, outermost first.
  ///
  /// This stays separate from `pullFrames`: an exit frame is popped before its
  /// selector and equality run, while the row must remain visibly computing
  /// until both have completed.
  private var computingPath: ContiguousArray<Int32> = []

  /// Whether traversal, selector capture, and post-selector publication are idle.
  ///
  /// Graph-owned system turns use this complete barrier rather than looking at
  /// frames alone, because a nested cold pull can empty its own frame suffix
  /// while an enclosing selector remains active.
  var isSettlementIdle: Bool {
    pullFrames.isEmpty && captures.isEmpty && computingPath.isEmpty
  }

  /// Rendered name of the innermost derived row still computing.
  ///
  /// The application commit guard reads this before opening a turn, covering
  /// both selector execution and custom equality just like the simple core.
  var innermostComputingName: String? {
    guard let rawRow = computingPath.last else { return nil }
    return cycleStep(forRow: liveRow(rawRow)).name
  }

  /// The innermost active row names used by the cold-nesting diagnostic.
  func innermostComputingNames(_ count: Int) -> [String] {
    computingPath.suffix(count).map { cycleStep(forRow: liveRow($0)).name }
  }

  /// Creates one empty arena graph and binds its selected edge propagator.
  init() {
    let arena = CogArenaStorage()
    let edges = CogSelectedArenaEdgeStorage()
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

      let changed = commit(slot, revision, propagation)
      #if DEBUG
      if changed {
        recordHistoryState(event: .write, slot: slot)
      }
      #endif
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

  #if DEBUG
  /// Publishes one pre-compared testing seed at the current arena revision.
  ///
  /// ``Cogs.seedForTesting(_:to:)`` owns the idle barrier, equality decision,
  /// and synchronized revision advance. This method updates only arena value
  /// and propagation columns, deliberately opening no turn or history event.
  func publishTestingSeed<Value>(_ value: Value, for valueReference: ManualCog<Value>) {
    let location = manualLocation(for: valueReference)
    location.column.publishSeed(
      value,
      at: location.slot,
      revision: revision,
      propagatingWith: propagation
    )
  }
  #endif

  /// Pulls one derived value current without recording a dependency.
  func derivedValue<Value>(for valueReference: Cog<Value>, in cogs: Cogs) -> Value {
    let location = derivedLocation(for: valueReference)
    settle(location.slot, in: cogs)
    return location.column.current(at: location.slot)
  }

  /// Renews grace after one transient manual-source demand.
  ///
  /// The value operation stays pure so testing seeds and internal tracked reads
  /// cannot accidentally create a sleeper. Public `peek` and ordinary writes
  /// call this explicit lifetime half after resolving the same stable identity.
  func scheduleLifetimeReleaseIfUnobserved<Value>(
    for valueReference: ManualCog<Value>,
    in cogs: Cogs
  ) {
    let location = manualLocation(for: valueReference)
    scheduleLifetimeReleaseIfUnobserved(location.slot, in: cogs)
  }

  /// Renews grace after one transient synchronous-derived demand.
  func scheduleLifetimeReleaseIfUnobserved<Value>(
    for valueReference: Cog<Value>,
    in cogs: Cogs
  ) {
    let location = derivedLocation(for: valueReference)
    scheduleLifetimeReleaseIfUnobserved(location.slot, in: cogs)
  }

  /// Reads one source through its lazily allocated Observation boundary.
  ///
  /// Resolving the value first installs the arena row; boundary access then
  /// records the exact public read without creating a graph dependency.
  func observedManualValue<Value>(for valueReference: ManualCog<Value>) -> Value {
    let location = manualLocation(for: valueReference)
    accessObservationBoundary(for: location.slot)
    return location.column.current(at: location.slot)
  }

  /// Settles and reads one derived row through its Observation boundary.
  ///
  /// Settlement precedes registration so cold computation establishes the
  /// consumer's baseline before later completed turns can invalidate it.
  func observedDerivedValue<Value>(for valueReference: Cog<Value>, in cogs: Cogs) -> Value {
    let location = derivedLocation(for: valueReference)
    settle(location.slot, in: cogs)
    accessObservationBoundary(for: location.slot)
    return location.column.current(at: location.slot)
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
  func lifetimePolicy<Value>(for valueReference: ManualCog<Value>) -> CogStateLifetime {
    let location = manualLocation(for: valueReference)
    return descriptorRecord(forRow: arena.index(of: location.slot)).lifetime
  }

  /// Descriptor lifetime restored by an installed derived arena row.
  func lifetimePolicy<Value>(for valueReference: Cog<Value>) -> CogStateLifetime {
    let location = derivedLocation(for: valueReference)
    return descriptorRecord(forRow: arena.index(of: location.slot)).lifetime
  }

  /// Durable reaction and UI owners of one installed manual arena row.
  func leaseCount<Value>(for valueReference: ManualCog<Value>) -> UInt32 {
    let location = manualLocation(for: valueReference)
    return arena.leaseCount[arena.index(of: location.slot)]
  }

  /// Durable reaction and UI owners of one installed derived arena row.
  func leaseCount<Value>(for valueReference: Cog<Value>) -> UInt32 {
    let location = derivedLocation(for: valueReference)
    return arena.leaseCount[arena.index(of: location.slot)]
  }

  /// Settles and notifies the boundary roots changed in this arena revision.
  ///
  /// The count snapshot preserves the simple core's baseline rule: a boundary
  /// created while another root settles joins the next flush and cannot receive
  /// a notice for a change that predates its first observed value.
  func flushObservationBoundaries(in cogs: Cogs) {
    let boundaryCount = observationEntries.count
    for entry in observationEntries.prefix(boundaryCount) {
      let row = arena.index(of: entry.slot)
      let record = descriptorRecord(forRow: row)
      if record.kind == .derived, needsSettlement(row) {
        settle(entry.slot, in: cogs)
      }

      guard arena.changedAt[row] == revision else { continue }
      #if DEBUG
      recordHistoryState(event: .notice, slot: entry.slot)
      #endif
      entry.boundary.notifyValueChange()
    }
  }

  /// Releases one unobserved derived row and allocates a replacement row.
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
    _ = derivedValue(for: releasedReference, in: cogs)
    let released = releaseDerivedState(for: releasedReference)

    let replacement = derivedLocation(for: replacementReference)
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
    _ = derivedValue(for: releasedReference, in: cogs)
    let released = releaseDerivedState(for: releasedReference)

    let replacement = derivedLocation(for: replacementReference)
    settle(replacement.slot, in: cogs)

    _ = arena.index(of: released)
  }

  #if DEBUG
  /// Records one outer turn in the arena-owned total history order.
  func recordHistoryTurn(named name: String) {
    historyLog.recordTurn(named: name)
  }

  /// Records a class-backed state event while its capability is still bridged.
  func recordHistoryState(event: CogHistoryEvent, label: CogLabel, key: CogKey?) {
    historyLog.recordState(event: event, label: label, key: key)
  }

  /// Records one reaction or watch body beside arena graph events.
  func recordHistoryEffect(label: CogLabel) {
    historyLog.recordEffect(label: label)
  }

  /// Public debug snapshot with descriptor labels resolved off the hot path.
  var historySnapshot: CogHistory {
    historyLog.snapshot { descriptorIndex in
      descriptorRecord(at: descriptorIndex).label
    }
  }

  /// Records an arena row as integer descriptor identity plus its erased key.
  private func recordHistoryState(event: CogHistoryEvent, slot: CogArenaSlot) {
    let row = arena.index(of: slot)
    let record = descriptorRecord(forRow: row)
    historyLog.recordState(
      event: event,
      descriptor: record.index,
      key: record.key(at: row)
    )
  }
  #endif

  /// Allocates one value-less terminal row for a reaction registration.
  ///
  /// The reaction object still owns its closure and cancellation identity, but
  /// dependency and subscriber topology terminates at this generated slot. A
  /// terminal has no descriptor, value column, boundary, or subscribers.
  func allocateReaction() -> CogArenaSlot {
    let slot = arena.allocate()
    arena.checkedAt[arena.index(of: slot)] = revision
    return slot
  }

  /// Reconciles one reaction terminal's ordered arena dependency prefix.
  ///
  /// Nested derived settlement temporarily pushes selector captures above this
  /// one. The generated slot therefore participates in the same concrete edge
  /// storage without a class-backed bridge or a second selector run.
  func captureReactionDependencies<Result>(
    for reaction: CogArenaSlot,
    _ body: () -> Result
  ) -> Result {
    _ = requireReactionRow(reaction)
    return withDependencyCapture(for: reaction, body)
  }

  /// Reconciles the durable leases owned by one completed reaction run.
  ///
  /// Only unique, directly read `whileObserved` producers enter the next set.
  /// Acquisitions happen before removals, so retracking a still-read root never
  /// exposes a false zero-count instant to the lifetime engine. Both buffers
  /// belong to the reaction object and trade roles after the pass, retaining
  /// their high-water capacities across steady runs.
  func reconcileReactionLeases(
    for reaction: CogArenaSlot,
    current: inout ContiguousArray<CogArenaSlot>,
    scratch: inout ContiguousArray<CogArenaSlot>,
    in cogs: Cogs
  ) {
    _ = requireReactionRow(reaction)
    scratch.removeAll(keepingCapacity: true)

    var cursor = edges.firstDependency(of: reaction.index, in: arena)
    while cursor != .none {
      let dependency = edges.dependency(at: cursor)
      guard dependency.consumer == reaction.index else {
        fatalError("Cog found another consumer's edge in an arena reaction lease list.")
      }
      let producerRow = liveRow(dependency.producer)
      let record = descriptorRecord(forRow: producerRow)
      if case .whileObserved = record.lifetime {
        let producer = CogArenaSlot(
          index: dependency.producer,
          generation: arena.generation[producerRow]
        )
        if !scratch.contains(producer) {
          scratch.append(producer)
        }
      }
      cursor = dependency.next
    }

    for producer in scratch where !current.contains(producer) {
      incrementLease(on: producer)
    }
    for producer in current where !scratch.contains(producer) {
      decrementLease(on: producer, schedulingIn: cogs)
    }

    swap(&current, &scratch)
    scratch.removeAll(keepingCapacity: true)
  }

  /// Releases every durable root owned by a cancelled arena reaction.
  func releaseReactionLeases(
    _ leases: inout ContiguousArray<CogArenaSlot>,
    in cogs: Cogs
  ) {
    for producer in leases {
      decrementLease(on: producer, schedulingIn: cogs)
    }
    leases.removeAll(keepingCapacity: true)
  }

  /// Balances reaction ownership while the enclosing context is disappearing.
  ///
  /// Teardown cancels all arena sleepers in one later pass, so beginning fresh
  /// grace here would create work that no state in this context can outlive.
  func releaseReactionLeasesForContextTeardown(
    _ leases: inout ContiguousArray<CogArenaSlot>
  ) {
    for producer in leases {
      decrementLeaseWithoutScheduling(on: producer)
    }
    leases.removeAll(keepingCapacity: true)
  }

  /// Whether propagation left CHECK or DIRTY work on one reaction terminal.
  func reactionNeedsSettlement(_ reaction: CogArenaSlot) -> Bool {
    needsSettlement(requireReactionRow(reaction))
  }

  /// Settles a reaction's arena producers and reports whether its body must run.
  ///
  /// Producer slots are copied into reused storage before pulls begin because a
  /// derived recomputation may recapture other lists in the shared edge pool.
  /// Equal recomputations leave their older `changedAt`, allowing this terminal
  /// to backdate and stay quiet exactly like an ordinary derived consumer.
  func settleReactionDependencies(_ reaction: CogArenaSlot, in cogs: Cogs) -> Bool {
    let reactionRow = requireReactionRow(reaction)
    guard needsSettlement(reactionRow) else { return false }
    guard reactionPullRoots.isEmpty else {
      fatalError("Cog tried to reenter arena reaction dependency settlement.")
    }
    defer { reactionPullRoots.removeAll(keepingCapacity: true) }

    var cursor = edges.firstDependency(of: reaction.index, in: arena)
    while cursor != .none {
      let dependency = edges.dependency(at: cursor)
      guard dependency.consumer == reaction.index else {
        fatalError("Cog found another consumer's edge in an arena reaction list.")
      }
      let producerRow = liveRow(dependency.producer)
      if needsSettlement(producerRow) {
        let record = descriptorRecord(forRow: producerRow)
        guard record.kind == .derived else {
          fatalError("Cog found an unsettled manual source behind an arena reaction.")
        }
        reactionPullRoots.append(
          CogArenaSlot(index: dependency.producer, generation: arena.generation[producerRow])
        )
      }
      cursor = dependency.next
    }

    for producer in reactionPullRoots {
      settle(producer, in: cogs)
    }

    let mustRun =
      arena.flags[reactionRow].contains(.dirty)
      || dependencyChanged(for: reaction.index)
    if !mustRun {
      completeReactionRun(reaction)
    }
    return mustRun
  }

  /// Marks a completed reaction body current and clears its terminal flags.
  func completeReactionRun(_ reaction: CogArenaSlot) {
    let row = requireReactionRow(reaction)
    arena.checkedAt[row] = revision
    arena.flags[row].remove(.check)
    arena.flags[row].remove(.dirty)
  }

  /// Removes one cancelled reaction's edges and returns its terminal slot.
  func releaseReaction(_ reaction: CogArenaSlot) {
    let row = requireReactionRow(reaction)
    guard !captures.contains(where: { $0.consumer == reaction }) else {
      fatalError("Cog tried to release an arena reaction during dependency capture.")
    }
    guard edges.firstSubscriber(of: reaction.index, in: arena) == .none else {
      fatalError("Cog found subscribers on an arena reaction terminal.")
    }
    guard arena.leaseCount[row] == 0 else {
      fatalError("Cog found durable leases on an arena reaction terminal.")
    }
    edges.removeDependencySuffix(of: reaction, after: .none, in: arena)
    guard arena.deps[row] == .none, arena.subs[row] == .none else {
      fatalError("Cog tried to release a linked arena reaction terminal.")
    }
    arena.release(reaction)
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

  /// Resolves a live descriptor-less row reserved for one reaction terminal.
  private func requireReactionRow(_ reaction: CogArenaSlot) -> Int {
    let row = arena.index(of: reaction)
    guard arena.descriptor[row] == CogArenaStorage.noIndex else {
      fatalError("Cog tried to use a value-state row as an arena reaction terminal.")
    }
    guard arena.boundary[row] == CogArenaStorage.noIndex else {
      fatalError("Cog found an Observation boundary on an arena reaction terminal.")
    }
    return row
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
      label: descriptor.label,
      kind: .manual,
      lifetime: descriptor.lifetime,
      column: column,
      commitSource: { slot, revision, propagation in
        column.commitSource(at: slot, revision: revision, propagatingWith: propagation)
      },
      recompute: nil,
      removeValue: { slot in column.remove(at: slot) }
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
      label: descriptor.label,
      kind: .derived,
      lifetime: descriptor.lifetime,
      column: column,
      commitSource: nil,
      recompute: { core, cogs, slot, key in
        core.recompute(descriptor: descriptor, column: column, slot: slot, key: key, in: cogs)
      },
      removeValue: { slot in column.remove(at: slot) }
    )
    return (record, column)
  }

  /// Registers one descriptor and returns its dense dispatch record.
  private func makeRecord(
    identity: ObjectIdentifier,
    label: CogLabel,
    kind: CogArenaDescriptorKind,
    lifetime: CogStateLifetime,
    column: AnyObject,
    commitSource: (@MainActor (CogArenaSlot, UInt32, CogSelectedArenaDirtyPropagation) -> Bool)?,
    recompute: (@MainActor (CogArenaCore, Cogs, CogArenaSlot, CogKey?) -> Void)?,
    removeValue: @escaping @MainActor (CogArenaSlot) -> Void
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
      commitSource: commitSource,
      recompute: recompute,
      removeValue: removeValue
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
    resetLifetimeEntry(at: row)
    record.install(key: key, at: row)
    slots[identity] = slot
    return slot
  }

  /// Removes one settled, unobserved derived state for the slot-reuse probe.
  ///
  /// Production grace expiry reaches the same erased release sequence. This
  /// typed entry only proves that the diagnostic names the expected descriptor
  /// before it deliberately returns the retired token to its caller.
  private func releaseDerivedState<Value>(for valueReference: Cog<Value>) -> CogArenaSlot {
    let identity = CogStateIdentity(
      descriptor: valueReference.descriptor.identity,
      key: valueReference.key
    )
    guard let slot = slots[identity] else {
      fatalError("Cog tried to release an arena derived state that was not installed.")
    }

    let setup = derivedRecord(for: valueReference.descriptor)
    let row = arena.index(of: slot)
    guard arena.descriptor[row] == setup.record.index else {
      fatalError("Cog tried to release an arena row through another descriptor.")
    }
    var ignoredDependencies: ContiguousArray<CogArenaSlot> = []
    releaseValueState(slot, appendingDependenciesTo: &ignoredDependencies)
    return slot
  }

  /// Records one ordinary UI value access on a slot's stable boundary.
  private func accessObservationBoundary(for slot: CogArenaSlot) {
    ensureObservationBoundary(for: slot).accessValue()
  }

  /// Returns the slot's existing boundary or creates its sole cold entry.
  ///
  /// The row stores only an `Int32` index. The ordered table owns the registrar
  /// object and exact slot generation, so graph walks never load a reference
  /// merely because a different row crossed the UI boundary.
  private func ensureObservationBoundary(for slot: CogArenaSlot) -> CogObservationBoundary {
    let row = arena.index(of: slot)
    let existingIndex = arena.boundary[row]
    if existingIndex != CogArenaStorage.noIndex {
      guard existingIndex >= 0, Int(existingIndex) < observationEntries.count else {
        fatalError("Cog found an arena row with an invalid Observation boundary index.")
      }
      let entry = observationEntries[Int(existingIndex)]
      guard entry.slot == slot else {
        fatalError("Cog found an Observation boundary attached to another arena slot lifetime.")
      }
      return entry.boundary
    }

    guard observationEntries.count <= Int(Int32.max) else {
      fatalError("Cog exhausted its Int32 Observation boundary index space.")
    }
    let boundary = CogObservationBoundary()
    incrementLease(on: slot)
    arena.boundary[row] = Int32(observationEntries.count)
    observationEntries.append(CogArenaObservationEntry(slot: slot, boundary: boundary))
    return boundary
  }

  /// Adds one durable owner to a releasable row without permitting wraparound.
  ///
  /// App-lifetime rows need no count: their descriptor policy alone keeps them
  /// resident. The count therefore stays a precise ownership proof only for
  /// rows whose zero transition can later begin grace.
  private func incrementLease(on slot: CogArenaSlot) {
    let row = arena.index(of: slot)
    guard case .whileObserved = descriptorRecord(forRow: row).lifetime else { return }
    cancelPendingLifetimeRelease(on: slot)
    guard arena.leaseCount[row] < UInt32.max else {
      fatalError("A Cog arena state's durable lifetime lease count overflowed.")
    }
    arena.leaseCount[row] += 1
  }

  /// Removes one durable owner and begins grace at the exact zero transition.
  private func decrementLease(on slot: CogArenaSlot, schedulingIn cogs: Cogs) {
    decrementLeaseWithoutScheduling(on: slot)
    let row = arena.index(of: slot)
    guard arena.leaseCount[row] == 0 else { return }
    guard arena.boundary[row] == CogArenaStorage.noIndex else { return }
    scheduleLifetimeReleaseIfUnobserved(slot, in: cogs)
  }

  /// Removes one owner without creating graph work during context teardown.
  private func decrementLeaseWithoutScheduling(on slot: CogArenaSlot) {
    let row = arena.index(of: slot)
    guard case .whileObserved = descriptorRecord(forRow: row).lifetime else { return }
    guard arena.leaseCount[row] > 0 else {
      fatalError("A Cog arena state's durable lifetime lease count underflowed.")
    }
    arena.leaseCount[row] -= 1
  }

  /// Starts or renews the sole grace sleeper for one transiently demanded row.
  ///
  /// Internal subscribers do not block scheduling. If they still retain the
  /// state at expiry, the check clears `pendingGeneration` and leaves the row
  /// for its downstream root's later release cascade.
  private func scheduleLifetimeReleaseIfUnobserved(
    _ slot: CogArenaSlot,
    in cogs: Cogs
  ) {
    let row = arena.index(of: slot)
    let record = descriptorRecord(forRow: row)
    guard case .whileObserved(let declaredGrace) = record.lifetime else { return }
    guard arena.leaseCount[row] == 0 else { return }
    guard arena.boundary[row] == CogArenaStorage.noIndex else { return }

    lifetimeEntries[row].task?.cancel()
    let generation = advanceLifetimeReleaseGeneration(at: row)
    lifetimeEntries[row].pendingGeneration = generation
    let grace = declaredGrace ?? cogs.defaultWhileObservedGrace
    let clock = cogs.clock

    lifetimeEntries[row].task = Task { @MainActor [weak self, weak cogs] in
      do {
        try await clock.sleep(for: grace)
      } catch {
        return
      }

      guard let self, let cogs else { return }
      self.releaseValueStateIfEligible(
        slot,
        lifetimeGeneration: generation,
        in: cogs
      )
    }
  }

  /// Checks one completed grace deadline against its exact row occupant.
  ///
  /// The check acknowledgement is consumed even when a lease, boundary,
  /// subscriber, renewal, release, or slot reuse makes the deadline ineligible.
  private func releaseValueStateIfEligible(
    _ slot: CogArenaSlot,
    lifetimeGeneration: UInt64,
    in cogs: Cogs
  ) {
    defer { cogs.acknowledgeLifetimeReleaseCheckIfRequested() }

    guard arena.contains(slot) else { return }
    let row = arena.index(of: slot)
    guard row < lifetimeEntries.count else { return }
    if lifetimeEntries[row].pendingGeneration == lifetimeGeneration {
      lifetimeEntries[row].pendingGeneration = nil
      lifetimeEntries[row].task = nil
    }

    guard lifetimeEntries[row].generation == lifetimeGeneration else { return }
    guard arena.leaseCount[row] == 0 else { return }
    guard case .whileObserved = descriptorRecord(forRow: row).lifetime else { return }
    guard arena.boundary[row] == CogArenaStorage.noIndex else { return }
    guard edges.firstSubscriber(of: slot.index, in: arena) == .none else { return }

    releaseUnobservedClosure(startingAt: slot)
    cogs.acknowledgeLifetimeReleaseIfRequested()
  }

  /// Releases the root and newly disconnected unobserved dependencies.
  ///
  /// A dependency with a future deadline keeps that independent grace. One
  /// whose own deadline already elapsed while subscribed has no pending token
  /// and leaves in this same iterative cascade, so internal edges never grant a
  /// second grace period.
  private func releaseUnobservedClosure(startingAt root: CogArenaSlot) {
    var candidates: ContiguousArray<CogArenaSlot> = [root]
    var index = 0

    while index < candidates.count {
      let slot = candidates[index]
      index += 1

      guard arena.contains(slot) else { continue }
      let row = arena.index(of: slot)
      guard arena.leaseCount[row] == 0 else { continue }
      guard case .whileObserved = descriptorRecord(forRow: row).lifetime else { continue }
      guard arena.boundary[row] == CogArenaStorage.noIndex else { continue }
      guard edges.firstSubscriber(of: slot.index, in: arena) == .none else { continue }
      guard slot == root || lifetimeEntries[row].pendingGeneration == nil else { continue }

      releaseValueState(slot, appendingDependenciesTo: &candidates)
    }
  }

  /// Removes one exact value row from topology, typed storage, and identity.
  ///
  /// Dependencies are captured before edge removal so newly unreferenced
  /// upstream states can join the same lifetime cascade. Every owner clears
  /// before the scalar index is returned for reuse.
  private func releaseValueState(
    _ slot: CogArenaSlot,
    appendingDependenciesTo candidates: inout ContiguousArray<CogArenaSlot>
  ) {
    let row = arena.index(of: slot)
    let record = descriptorRecord(forRow: row)
    guard arena.boundary[row] == CogArenaStorage.noIndex else {
      fatalError("Cog tried to release an arena state pinned by a UI boundary.")
    }
    guard arena.leaseCount[row] == 0 else {
      fatalError("Cog tried to release an arena state with durable leases.")
    }
    guard edges.firstSubscriber(of: slot.index, in: arena) == .none else {
      fatalError("Cog tried to release an arena state with live subscribers.")
    }
    guard !arena.flags[row].contains(.computing), !arena.flags[row].contains(.touched) else {
      fatalError("Cog tried to release an arena state during active graph work.")
    }

    var cursor = edges.firstDependency(of: slot.index, in: arena)
    while cursor != .none {
      let dependency = edges.dependency(at: cursor)
      guard dependency.consumer == slot.index else {
        fatalError("Cog found another consumer's edge in an arena release list.")
      }
      let producerRow = liveRow(dependency.producer)
      candidates.append(
        CogArenaSlot(index: dependency.producer, generation: arena.generation[producerRow])
      )
      cursor = dependency.next
    }

    let key = record.key(at: row)
    let identity = CogStateIdentity(descriptor: record.identity, key: key)
    cancelPendingLifetimeRelease(on: slot)
    edges.removeDependencySuffix(of: slot, after: .none, in: arena)
    record.removeValue(slot)
    record.removeKey(at: row)
    guard slots.removeValue(forKey: identity) == slot else {
      fatalError("Cog removed a different arena slot from state identity storage.")
    }
    arena.release(slot)
  }

  /// Cancels a sleeper before a lease, release, or context teardown can race it.
  private func cancelPendingLifetimeRelease(on slot: CogArenaSlot) {
    let row = arena.index(of: slot)
    _ = advanceLifetimeReleaseGeneration(at: row)
    lifetimeEntries[row].pendingGeneration = nil
    lifetimeEntries[row].task?.cancel()
    lifetimeEntries[row].task = nil
  }

  /// Advances a row's deadline token without permitting stale-token wraparound.
  private func advanceLifetimeReleaseGeneration(at row: Int) -> UInt64 {
    guard lifetimeEntries[row].generation < UInt64.max else {
      fatalError("A Cog arena state's lifetime release generation overflowed.")
    }
    lifetimeEntries[row].generation += 1
    return lifetimeEntries[row].generation
  }

  /// Installs empty cold metadata for a newly allocated value-row occupant.
  private func resetLifetimeEntry(at row: Int) {
    if row >= lifetimeEntries.count {
      lifetimeEntries.append(
        contentsOf: repeatElement(CogArenaLifetimeEntry(), count: row + 1 - lifetimeEntries.count)
      )
      return
    }

    lifetimeEntries[row].task?.cancel()
    lifetimeEntries[row] = CogArenaLifetimeEntry()
  }

  /// Cancels every arena-owned sleeper before the enclosing context disappears.
  func prepareForContextTeardown() {
    for row in lifetimeEntries.indices where lifetimeEntries[row].task != nil {
      guard lifetimeEntries[row].generation < UInt64.max else {
        fatalError("A Cog arena state's lifetime release generation overflowed.")
      }
      lifetimeEntries[row].generation += 1
      lifetimeEntries[row].pendingGeneration = nil
      lifetimeEntries[row].task?.cancel()
      lifetimeEntries[row].task = nil
    }
  }

  /// Resolves one row's descriptor record without retaining it in the walk.
  private func descriptorRecord(forRow row: Int) -> CogArenaDescriptorRecord {
    let descriptorIndex = arena.descriptor[row]
    guard descriptorIndex >= 0, Int(descriptorIndex) < records.count else {
      fatalError("Cog found a live arena row without descriptor dispatch.")
    }
    return records[Int(descriptorIndex)].takeUnretainedValue()
  }

  #if DEBUG
  /// Resolves one descriptor dispatch index while materializing debug history.
  private func descriptorRecord(at rawIndex: Int32) -> CogArenaDescriptorRecord {
    guard rawIndex >= 0, Int(rawIndex) < records.count else {
      fatalError("Cog found an invalid arena descriptor index in debug history.")
    }
    return records[Int(rawIndex)].takeUnretainedValue()
  }
  #endif

  /// Pulls one derived row current through reusable scalar enter/exit frames.
  private func settle(_ root: CogArenaSlot, in cogs: Cogs) {
    cogs.settleDepth += 1
    defer { cogs.settleDepth -= 1 }
    if cogs.settleDepth > Cogs.maximumSettleDepth {
      fatalError(
        cogs.coldSettleDepthMessage(
          innermostComputingNames: innermostComputingNames(8)
        )
      )
    }

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

        if let cycle = cyclePath(ifEnteringRow: row) {
          fatalError(cycle.message)
        }

        beginComputing(row)
        pullFrames.append(CogArenaPullFrame(row: frame.row, phase: .exit))
        appendDependencies(of: frame.row)

      case .exit:
        defer { endComputing(row) }
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
    var cursor = edges.firstDependency(of: consumerRow, in: arena)
    while cursor != .none {
      let dependency = edges.dependency(at: cursor)
      guard dependency.consumer == consumerRow else {
        fatalError("Cog found another consumer's edge in an arena dependency list.")
      }
      let producerRow = liveRow(dependency.producer)
      if needsSettlement(producerRow) {
        pullFrames.append(CogArenaPullFrame(row: dependency.producer, phase: .enter))
      }
      cursor = dependency.next
    }
  }

  /// Whether any dependency changed after this consumer was last current.
  private func dependencyChanged(for consumerRow: Int32) -> Bool {
    let checkedAt = arena.checkedAt[Int(consumerRow)]
    var cursor = edges.firstDependency(of: consumerRow, in: arena)
    while cursor != .none {
      let dependency = edges.dependency(at: cursor)
      guard dependency.consumer == consumerRow else {
        fatalError("Cog found another consumer's edge in an arena dependency list.")
      }
      if arena.changedAt[liveRow(dependency.producer)] > checkedAt {
        return true
      }
      cursor = dependency.next
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
    #if DEBUG
    recordHistoryState(event: .recompute, slot: slot)
    #endif
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
        cursor: edges.firstDependency(of: Int32(row), in: arena),
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
      let dependency = edges.dependency(at: capture.cursor)
      if dependency.producer == producer.index, dependency.consumer == consumer.index {
        edges.updateVersion(
          of: capture.cursor,
          to: arena.changedAt[arena.index(of: producer)]
        )
        capture.previous = capture.cursor
        capture.cursor = dependency.next
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

  /// Returns the closed active-path suffix when `row` is already computing.
  ///
  /// The packed row bit is the common fast path. Only a detected cycle scans
  /// and renders the ordered path, so ordinary settlement does no identity or
  /// key work beyond the scalar flag check.
  private func cyclePath(ifEnteringRow row: Int) -> CogCyclePath? {
    guard arena.flags[row].contains(.computing) else { return nil }
    let rawRow = Int32(row)
    guard let first = computingPath.firstIndex(of: rawRow) else {
      fatalError("An arena row was marked computing without an active path entry.")
    }
    let steps =
      computingPath[first...].map { cycleStep(forRow: liveRow($0)) }
      + [cycleStep(forRow: row)]
    return CogCyclePath(steps: steps)
  }

  /// Marks and appends one row after cycle detection has succeeded.
  private func beginComputing(_ row: Int) {
    guard cyclePath(ifEnteringRow: row) == nil else {
      fatalError("Cog tried to enter an arena derived cycle without reporting it.")
    }
    arena.flags[row].insert(.computing)
    computingPath.append(Int32(row))
  }

  /// Clears the innermost row while enforcing balanced nested settlement.
  private func endComputing(_ row: Int) {
    guard computingPath.last == Int32(row) else {
      fatalError("Cog tried to finish arena derived computation out of path order.")
    }
    computingPath.removeLast()
    arena.flags[row].remove(.computing)
  }

  /// Erases one row into the renderer shared by both runtime cores.
  private func cycleStep(forRow row: Int) -> CogCycleStep {
    let record = descriptorRecord(forRow: row)
    return CogCycleStep(
      descriptor: record.identity,
      label: record.label,
      key: record.key(at: row)
    )
  }

  /// Diagnoses a hypothetical derived read without creating a row or edge.
  ///
  /// The lookup is intentionally observational. A missing descriptor-and-key
  /// identity returns `nil`, preserving lazy row creation and later edge order.
  func cycleDiagnosticSnapshot<Value>(
    ifReading valueReference: Cog<Value>
  ) -> CogCycleDiagnosticSnapshot? {
    let identity = CogStateIdentity(
      descriptor: valueReference.descriptor.identity,
      key: valueReference.key
    )
    guard let slot = slots[identity] else { return nil }
    let row = arena.index(of: slot)
    return cyclePath(ifEnteringRow: row)?.snapshot
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
