#if COG_CORE_ARENA

/// Whether one arena async row has accepted a successful value.
///
/// A dedicated enum preserves a successful optional `nil` distinctly from no
/// success without adding another optional layer to every status operation.
private enum CogArenaAsyncSuccess<Value> {
  /// No generation has succeeded for this row occupant.
  case absent

  /// The latest value accepted from this row occupant's work.
  case value(Value)
}

/// Descriptor-local task and status sidecars for arena-backed async rows.
///
/// Status itself lives in a concrete ``CogArenaValueColumn`` and participates
/// in the arena's scalar versions and indexed topology. Cold runtime concerns
/// that cannot be scalar—tasks, generation waiters, retained successes, and
/// Observation field masks—live here once per descriptor and are indexed by
/// the same global row. No async state object enters the graph or a hot edge.
@MainActor
internal final class CogArenaAsyncColumn<Value> {
  /// Scalar arena whose exact slot lifetimes govern every sidecar cell.
  private let arena: CogArenaStorage

  /// Immutable declaration supplying selection, defaults, equality, and label.
  private let descriptor: AsyncCogDescriptor<Value>

  /// Atomic completed and pending status values for this descriptor's rows.
  let statuses: CogArenaValueColumn<CogStatus<Value>>

  /// Whether this descriptor currently owns each global arena row.
  private var installed: ContiguousArray<Bool> = []

  /// Newest task retained for each installed row occupant.
  private var activeTasks: ContiguousArray<Task<Void, Never>?> = []

  /// Monotonic work identity scoped to one exact installed row lifetime.
  private var generations: ContiguousArray<UInt64> = []

  /// Latest accepted success retained through later pending and failure turns.
  private var successes: ContiguousArray<CogArenaAsyncSuccess<Value>> = []

  /// Exact-generation explicit refresh cells, cold and normally empty.
  private var refreshWaiters: ContiguousArray<[UInt64: CogRefreshWaiter<Value>]> = []

  /// Status fields changed by the pending publication for each row.
  private var observationChanges: ContiguousArray<CogStatusObservationFields> = []

  /// Creates the async sidecars and their concrete status value column.
  init(in arena: CogArenaStorage, descriptor: AsyncCogDescriptor<Value>) {
    self.arena = arena
    self.descriptor = descriptor
    self.statuses = CogArenaValueColumn(in: arena)
  }

  /// Installs empty task metadata for one newly allocated descriptor row.
  func install(at slot: CogArenaSlot) {
    let row = arena.index(of: slot)
    ensureStorage(through: row)
    guard !installed[row], !statuses.contains(slot) else {
      fatalError("Cog tried to install two async states in one arena descriptor row.")
    }
    activeTasks[row]?.cancel()
    installed[row] = true
    activeTasks[row] = nil
    generations[row] = 0
    successes[row] = .absent
    refreshWaiters[row].removeAll(keepingCapacity: false)
    observationChanges[row] = []
  }

  /// Whether first demand has installed this row's pending status baseline.
  func hasStatus(at slot: CogArenaSlot) -> Bool {
    let row = installedRow(for: slot)
    return statuses.contains(slot) && installed[row]
  }

  /// Returns the newest completed status after the arena has settled this row.
  func status(at slot: CogArenaSlot) -> CogStatus<Value> {
    _ = installedRow(for: slot)
    return statuses.current(at: slot)
  }

  /// Returns the current generation so initial refresh can attach its waiter.
  func generation(at slot: CogArenaSlot) -> UInt64 {
    generations[installedRow(for: slot)]
  }

  /// Files one explicit refresh cell under the generation it must follow.
  func register(_ waiter: CogRefreshWaiter<Value>, for generation: UInt64, at slot: CogArenaSlot) {
    let row = installedRow(for: slot)
    guard refreshWaiters[row][generation] == nil else {
      fatalError("An async Cog created two refresh handles for one arena generation.")
    }
    refreshWaiters[row][generation] = waiter
  }

  /// Starts selected work after the arena has reconciled synchronous dependencies.
  ///
  /// First demand installs pending synchronously and queues its named empty
  /// turn. Reload during another turn stages pending into the next ordered
  /// system turn; explicit refresh may supply its already-open pending turn.
  @discardableResult
  func startWork(
    _ work: Work<Value>,
    at slot: CogArenaSlot,
    key: CogKey?,
    publishingPendingIn pendingTurn: CogTurn? = nil,
    refreshWaiter: CogRefreshWaiter<Value>? = nil,
    in core: CogArenaCore,
    cogs: Cogs
  ) -> UInt64 {
    let row = installedRow(for: slot)
    let retained = successes[row]
    let pending: CogStatus<Value> =
      switch retained {
      case .absent:
        .pending(value: descriptor.defaultValue, hasSucceeded: false)
      case .value(let value):
        .pending(value: value, hasSucceeded: true)
      }

    if let pendingTurn {
      stage(pending, at: slot, in: pendingTurn, core: core)
    } else if !statuses.contains(slot) {
      statuses.insert(pending, at: slot)
      arena.changedAt[row] = core.revision
      cogs.withSystemTurn("\(renderedName(for: key)) pending") { _ in }
    } else {
      switch cogs.turnPhase {
      case .idle:
        statuses.stage(pending, at: slot)
        _ = statuses.commit(at: slot)
        arena.changedAt[row] = core.revision
        cogs.withSystemTurn("\(renderedName(for: key)) pending") { _ in }
      case .accumulating, .flushing:
        stage(pending, named: "pending", at: slot, key: key, in: core, cogs: cogs)
      }
    }

    resolveRefreshes(at: row, as: .superseded)
    let generation = advanceGeneration(at: row)
    if let refreshWaiter {
      register(refreshWaiter, for: generation, at: slot)
    }
    activeTasks[row]?.cancel()

    let operation = work.operation
    activeTasks[row] = Task(name: renderedName(for: key)) { @MainActor [weak self, weak cogs] in
      do {
        let value = try await operation()
        guard let self, let cogs else { return }
        defer { cogs.acknowledgeAsyncCompletionCheckIfRequested() }
        guard self.acceptsResult(for: generation, at: slot, in: cogs.arenaCore) else {
          self.resolveRefresh(at: slot, for: generation, as: .superseded)
          return
        }
        let row = self.installedRow(for: slot)
        self.successes[row] = .value(value)
        self.publish(.success(value), named: "success", at: slot, key: key, in: cogs)
        self.resolveRefresh(at: slot, for: generation, as: .success(value))
      } catch {
        guard let self, let cogs else { return }
        defer { cogs.acknowledgeAsyncCompletionCheckIfRequested() }
        guard !Task.isCancelled,
          self.acceptsResult(for: generation, at: slot, in: cogs.arenaCore)
        else {
          self.resolveRefresh(at: slot, for: generation, as: .superseded)
          return
        }
        let row = self.installedRow(for: slot)
        let failure: CogStatus<Value> =
          switch self.successes[row] {
          case .absent:
            .failure(error, value: self.descriptor.defaultValue, hasSucceeded: false)
          case .value(let value):
            .failure(error, value: value, hasSucceeded: true)
          }
        self.publish(failure, named: "failure", at: slot, key: key, in: cogs)
        self.resolveRefresh(at: slot, for: generation, as: .failure(error))
      }
    }
    return generation
  }

  /// Publishes one pending arena status through the turn's scalar source pass.
  func commitPending(
    at slot: CogArenaSlot,
    revision: UInt32,
    propagatingWith propagation: CogSelectedArenaDirtyPropagation
  ) -> Bool {
    _ = installedRow(for: slot)
    return statuses.commitSource(
      at: slot,
      revision: revision,
      propagatingWith: propagation
    )
  }

  /// Sends only the status-field mutations computed for this publication.
  func notifyObservation(at slot: CogArenaSlot, through boundary: CogObservationBoundary) {
    let row = installedRow(for: slot)
    let changes = observationChanges[row]
    observationChanges[row] = []
    boundary.notifyStatusChanges(changes)
  }

  /// Cancels work and clears every sidecar before a scalar row is reused.
  func remove(at slot: CogArenaSlot) {
    let row = installedRow(for: slot)
    resolveRefreshes(at: row, as: .released)
    _ = advanceGeneration(at: row)
    activeTasks[row]?.cancel()
    activeTasks[row] = nil
    if statuses.contains(slot) {
      statuses.remove(at: slot)
    }
    installed[row] = false
    successes[row] = .absent
    observationChanges[row] = []
  }

  /// Invalidates and cancels every installed task before context ARC teardown.
  func prepareForContextTeardown() {
    for row in installed.indices where installed[row] {
      resolveRefreshes(at: row, as: .released)
      _ = advanceGeneration(at: row)
      activeTasks[row]?.cancel()
      activeTasks[row] = nil
    }
  }

  /// Whether one completed generation may still publish into its exact slot.
  private func acceptsResult(
    for generation: UInt64,
    at slot: CogArenaSlot,
    in core: CogArenaCore
  ) -> Bool {
    guard core.stillStores(slot, descriptor: descriptor) else { return false }
    let row = installedRow(for: slot)
    guard generations[row] == generation else { return false }
    let flags = arena.flags[row]
    guard !flags.contains(.dirty), !flags.contains(.check) else {
      activeTasks[row] = nil
      arena.flags[row].remove(.check)
      arena.flags[row].insert(.dirty)
      return false
    }
    return true
  }

  /// Stages one accepted result as its own named graph-owned turn.
  private func publish(
    _ status: CogStatus<Value>,
    named statusName: String,
    at slot: CogArenaSlot,
    key: CogKey?,
    in cogs: Cogs
  ) {
    activeTasks[installedRow(for: slot)] = nil
    stage(status, named: statusName, at: slot, key: key, in: cogs.arenaCore, cogs: cogs)
  }

  /// Queues or runs a named system turn that stages one status snapshot.
  private func stage(
    _ status: CogStatus<Value>,
    named statusName: String,
    at slot: CogArenaSlot,
    key: CogKey?,
    in core: CogArenaCore,
    cogs: Cogs
  ) {
    cogs.withSystemTurn("\(renderedName(for: key)) \(statusName)") { [weak self, weak cogs] turn in
      guard let self, let cogs,
        cogs.arenaCore === core,
        core.stillStores(slot, descriptor: self.descriptor)
      else { return }
      self.stage(status, at: slot, in: turn, core: core)
    }
  }

  /// Fills the pending status cell and registers the row once with this turn.
  private func stage(
    _ status: CogStatus<Value>,
    at slot: CogArenaSlot,
    in turn: CogTurn,
    core: CogArenaCore
  ) {
    let row = installedRow(for: slot)
    let previous = statuses.current(at: slot)
    observationChanges[row] = status.observationChanges(from: previous) {
      descriptor.valuesAreEqual($0, $1)
    }
    statuses.stage(status, at: slot)
    core.touchArenaSource(slot, in: turn)
  }

  /// Resolves and removes one explicit generation's waiter, if present.
  private func resolveRefresh(
    at slot: CogArenaSlot,
    for generation: UInt64,
    as outcome: CogRefresh<Value>.Outcome
  ) {
    guard arena.contains(slot) else { return }
    let row = Int(slot.index)
    guard row < installed.count, installed[row] else { return }
    refreshWaiters[row].removeValue(forKey: generation)?.resolve(outcome)
  }

  /// Resolves every waiter still filed on one row occupant.
  private func resolveRefreshes(at row: Int, as outcome: CogRefresh<Value>.Outcome) {
    let waiters = Array(refreshWaiters[row].values)
    refreshWaiters[row].removeAll(keepingCapacity: false)
    for waiter in waiters {
      waiter.resolve(outcome)
    }
  }

  /// Advances one row's generation without permitting stale-identity wraparound.
  private func advanceGeneration(at row: Int) -> UInt64 {
    guard generations[row] < UInt64.max else {
      fatalError("An arena async Cog exhausted its work generation counter.")
    }
    generations[row] += 1
    return generations[row]
  }

  /// Renders the descriptor label and optional key for turns and task tools.
  private func renderedName(for key: CogKey?) -> String {
    guard let key else { return "\(descriptor.label)" }
    return "\(descriptor.label)[\(key.erased.base)]"
  }

  /// Extends every cold sidecar through one newly used global arena row.
  private func ensureStorage(through row: Int) {
    guard row >= installed.count else { return }
    let missing = row + 1 - installed.count
    installed.append(contentsOf: repeatElement(false, count: missing))
    activeTasks.append(contentsOf: repeatElement(nil, count: missing))
    generations.append(contentsOf: repeatElement(0, count: missing))
    successes.append(contentsOf: repeatElement(.absent, count: missing))
    refreshWaiters.append(contentsOf: repeatElement([:], count: missing))
    observationChanges.append(contentsOf: repeatElement([], count: missing))
  }

  /// Validates one exact slot and this descriptor's ownership of its row.
  private func installedRow(for slot: CogArenaSlot) -> Int {
    let row = arena.index(of: slot)
    guard row < installed.count, installed[row] else {
      fatalError("Cog tried to use an empty arena async descriptor row.")
    }
    return row
  }

  // Written out, and `nonisolated`, because generic classes under the
  // package's MainActor default otherwise crash the pinned release optimizer.
  nonisolated deinit {}
}

#endif
