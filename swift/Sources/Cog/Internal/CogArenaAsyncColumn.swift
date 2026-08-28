/// One ordered arena request selected before its operation may start.
///
/// The selector has already captured this request's dependencies. Queue keeps
/// every instance in FIFO order; exhaust-latest retains only the newest one.
/// Generation binds any explicit refresh waiter to this exact request.
private struct CogArenaDeferredRun<Value> {
  /// Stable identity assigned when the selector accepted this request.
  let generation: UInt64

  /// One-shot operation deferred until the row's scheduler admits it.
  let operation: @Sendable @isolated(any) () async throws -> sending Value
}

/// Whether one arena async row has accepted a successful value.
///
/// The enum keeps a successful optional `nil` separate from no success. Status
/// code does not need another optional layer.
private enum CogArenaAsyncSuccess<Value> {
  /// No generation has succeeded for this row occupant.
  case absent

  /// The latest value accepted from this row occupant's work.
  case value(Value)
}

/// Descriptor-local task and status sidecars for arena-backed async rows.
///
/// Status lives in a ``CogArenaValueColumn`` and uses the arena's scalar
/// versions and topology. Tasks, generation waiters, retained successes, and
/// Observation field masks need typed storage. They live here once per
/// descriptor and use the same global row. No async state object enters a hot
/// graph edge.
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

  /// Active task retained for each non-merged row occupant.
  ///
  /// Queue and exhaust keep this task until their admitted run finishes;
  /// latest replaces it on every selection.
  private var activeTasks: ContiguousArray<Task<Void, Never>?> = []

  /// Every independently eligible merged task, by row and generation.
  private var activeMergedTasks: ContiguousArray<[UInt64: Task<Void, Never>]> = []

  /// Exact admitted generation for queue and exhaust-latest rows.
  ///
  /// Later deferred selections advance `generations` without changing this
  /// identity, so the active result remains eligible until it finishes.
  private var activeRunGenerations: ContiguousArray<UInt64?> = []

  /// FIFO requests selected while one queue operation remains active.
  private var queuedRuns: ContiguousArray<[CogArenaDeferredRun<Value>]> = []

  /// Newest request selected while one exhaust-latest operation remains active.
  private var exhaustCatchUps: ContiguousArray<CogArenaDeferredRun<Value>?> = []

  /// Monotonic work identity scoped to one exact installed row lifetime.
  private var generations: ContiguousArray<UInt64> = []

  /// Latest accepted success retained through later pending and failure turns.
  private var successes: ContiguousArray<CogArenaAsyncSuccess<Value>> = []

  /// This row's own resting default, produced once when the row was installed.
  ///
  /// The declaration supplies a closure, so each state must store the result.
  /// Calling it once per row gives pending, failure, and retry-pending statuses
  /// the same value until the first success. A
  /// released row clears the cell, so the next install produces a fresh
  /// default, which is exactly the `whileObserved` reset async state expects.
  ///
  /// `nil` means the row is not installed; an installed row always holds a
  /// value.
  private var defaults: ContiguousArray<Value?> = []

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
    for task in activeMergedTasks[row].values {
      task.cancel()
    }
    installed[row] = true
    activeTasks[row] = nil
    activeMergedTasks[row].removeAll(keepingCapacity: false)
    activeRunGenerations[row] = nil
    queuedRuns[row].removeAll(keepingCapacity: false)
    exhaustCatchUps[row] = nil
    generations[row] = 0
    successes[row] = .absent
    defaults[row] = descriptor.makeDefaultValue()
    refreshWaiters[row].removeAll(keepingCapacity: false)
    observationChanges[row] = []
  }

  /// This row's resting default, produced when the row was installed.
  ///
  /// Traps rather than re-producing a default for an uninstalled row: every
  /// caller reaches this after ``installedRow(for:)`` has already proven the row
  /// is live, so a missing cell is storage corruption, not a cold path.
  private func defaultValue(at row: Int) -> Value {
    guard let value = defaults[row] else {
      fatalError(
        """
        Cog asked \(descriptor.label) for the resting default of an async state \
        that is not installed. An installed row always holds the default it \
        produced at installation, so this context's async storage is corrupt.
        """
      )
    }
    return value
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
    let generation = advanceGeneration(at: row)
    switch work.storage {
    case .run(let operation):
      switch descriptor.policy {
      case .queue:
        if let refreshWaiter {
          register(refreshWaiter, for: generation, at: slot)
        }
        let run = CogArenaDeferredRun(generation: generation, operation: operation)
        if activeTasks[row] == nil {
          beginDeferredRun(
            run,
            at: slot,
            key: key,
            publishingPendingIn: pendingTurn,
            in: core,
            cogs: cogs
          )
        } else {
          queuedRuns[row].append(run)
        }

      case .exhaustLatest:
        let run = CogArenaDeferredRun(generation: generation, operation: operation)
        if activeTasks[row] == nil {
          resolveRefreshes(at: row, as: .superseded)
          if let refreshWaiter {
            register(refreshWaiter, for: generation, at: slot)
          }
          beginDeferredRun(
            run,
            at: slot,
            key: key,
            publishingPendingIn: pendingTurn,
            in: core,
            cogs: cogs
          )
        } else {
          if let replaced = exhaustCatchUps[row] {
            resolveRefresh(at: slot, for: replaced.generation, as: .superseded)
          }
          if let refreshWaiter {
            register(refreshWaiter, for: generation, at: slot)
          }
          exhaustCatchUps[row] = run
        }

      case .merged:
        publishPending(at: slot, key: key, in: pendingTurn, core: core, cogs: cogs)
        if let refreshWaiter {
          register(refreshWaiter, for: generation, at: slot)
        }
        launchRun(operation, generation: generation, at: slot, key: key, cogs: cogs)

      case .latest:
        publishPending(at: slot, key: key, in: pendingTurn, core: core, cogs: cogs)
        resolveRefreshes(at: row, as: .superseded)
        if let refreshWaiter {
          register(refreshWaiter, for: generation, at: slot)
        }
        activeTasks[row]?.cancel()
        launchRun(operation, generation: generation, at: slot, key: key, cogs: cogs)
      }

    case .stream(let stream):
      guard descriptor.policy == .latest else {
        fatalError("Ordered async work reached the arena runtime with a stream.")
      }
      publishPending(at: slot, key: key, in: pendingTurn, core: core, cogs: cogs)
      resolveRefreshes(at: row, as: .superseded)
      if let refreshWaiter {
        register(refreshWaiter, for: generation, at: slot)
      }
      activeTasks[row]?.cancel()
      launchStream(stream, generation: generation, at: slot, key: key, cogs: cogs)
    }
    return generation
  }

  /// Creates one one-shot task under the descriptor policy's eligibility rule.
  private func launchRun(
    _ operation: @escaping @Sendable @isolated(any) () async throws -> sending Value,
    generation: UInt64,
    at slot: CogArenaSlot,
    key: CogKey?,
    cogs: Cogs
  ) {
    let row = installedRow(for: slot)
    let task = Task(name: renderedName(for: key)) { @MainActor [weak self, weak cogs] in
      do {
        let value = try await operation()
        guard let self, let cogs else { return }
        defer { cogs.acknowledge(.asyncCompletionCheck) }
        guard self.acceptsResult(for: generation, at: slot, in: cogs.arenaCore) else {
          self.resolveRefresh(at: slot, for: generation, as: .superseded)
          return
        }
        let row = self.installedRow(for: slot)
        self.successes[row] = .value(value)
        self.publish(
          .success(value),
          completing: generation,
          named: "success",
          at: slot,
          key: key,
          in: cogs
        )
        self.resolveRefresh(at: slot, for: generation, as: .success(value))
        self.advanceOrderedScheduler(at: slot, key: key, in: cogs.arenaCore, cogs: cogs)
      } catch {
        guard let self, let cogs else { return }
        defer { cogs.acknowledge(.asyncCompletionCheck) }
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
            .failure(error, value: self.defaultValue(at: row), hasSucceeded: false)
          case .value(let value):
            .failure(error, value: value, hasSucceeded: true)
          }
        self.publish(
          failure,
          completing: generation,
          named: "failure",
          at: slot,
          key: key,
          in: cogs
        )
        self.resolveRefresh(at: slot, for: generation, as: .failure(error))
        self.advanceOrderedScheduler(at: slot, key: key, in: cogs.arenaCore, cogs: cogs)
      }
    }
    if descriptor.policy == .merged {
      activeMergedTasks[row][generation] = task
    } else {
      activeRunGenerations[row] = generation
      activeTasks[row] = task
    }
  }

  /// Publishes pending exactly when an accepted request starts executing.
  ///
  /// Queue and exhaust may select work several turns before this method runs.
  /// Delaying pending keeps the visible lifecycle aligned with the one admitted
  /// operation instead of claiming deferred work is already in flight.
  private func publishPending(
    at slot: CogArenaSlot,
    key: CogKey?,
    in pendingTurn: CogTurn?,
    requiringPublicationTurn: Bool = false,
    core: CogArenaCore,
    cogs: Cogs
  ) {
    let row = installedRow(for: slot)
    let pending: CogStatus<Value> =
      switch successes[row] {
      case .absent:
        .pending(value: defaultValue(at: row), hasSucceeded: false)
      case .value(let value):
        .pending(value: value, hasSucceeded: true)
      }

    if let pendingTurn {
      stage(pending, at: slot, in: pendingTurn, core: core)
    } else if requiringPublicationTurn {
      stage(pending, named: "pending", at: slot, key: key, in: core, cogs: cogs)
    } else if !statuses.contains(slot) {
      statuses.insert(pending, at: slot)
      arena.changedAt[row] = core.revision
      cogs.withSystemTurn("\(renderedName(for: key)) pending") { _ in }
    } else {
      switch cogs.turnPhase {
      case .idle:
        statuses.stage(pending, at: slot)
        _ = statuses.publish(at: slot)
        arena.changedAt[row] = core.revision
        cogs.withSystemTurn("\(renderedName(for: key)) pending") { _ in }
      case .accumulating, .flushing:
        stage(pending, named: "pending", at: slot, key: key, in: core, cogs: cogs)
      }
    }
  }

  /// Admits one ordered operation after publishing its pending transition.
  private func beginDeferredRun(
    _ run: CogArenaDeferredRun<Value>,
    at slot: CogArenaSlot,
    key: CogKey?,
    publishingPendingIn pendingTurn: CogTurn? = nil,
    requiringPublicationTurn: Bool = false,
    in core: CogArenaCore,
    cogs: Cogs
  ) {
    let row = installedRow(for: slot)
    guard activeTasks[row] == nil, activeRunGenerations[row] == nil else {
      fatalError("An arena ordered async scheduler tried to start two runs at once.")
    }
    publishPending(
      at: slot,
      key: key,
      in: pendingTurn,
      requiringPublicationTurn: requiringPublicationTurn,
      core: core,
      cogs: cogs
    )
    launchRun(
      run.operation,
      generation: run.generation,
      at: slot,
      key: key,
      cogs: cogs
    )
  }

  /// Creates and owns the iterator task for one latest stream generation.
  private func launchStream(
    _ stream: WorkStream<Value>,
    generation: UInt64,
    at slot: CogArenaSlot,
    key: CogKey?,
    cogs: Cogs
  ) {
    let row = installedRow(for: slot)
    activeRunGenerations[row] = generation
    activeTasks[row] = Task(name: renderedName(for: key)) { @MainActor [weak self, weak cogs] in
      let iterator = stream.makeIterator()
      do {
        while let value = try await iterator.next() {
          guard let cogs else { return }
          guard let self else {
            cogs.acknowledge(.asyncCompletionCheck)
            return
          }
          guard self.acceptsResult(for: generation, at: slot, in: cogs.arenaCore) else {
            self.resolveRefresh(at: slot, for: generation, as: .superseded)
            cogs.acknowledge(.asyncCompletionCheck)
            return
          }

          let row = self.installedRow(for: slot)
          let changed =
            switch self.successes[row] {
            case .absent:
              true
            case .value(let previous):
              !self.descriptor.valuesAreEqual(previous, value)
            }
          if changed {
            self.successes[row] = .value(value)
            self.stage(
              .success(value),
              named: "success",
              at: slot,
              key: key,
              in: cogs.arenaCore,
              cogs: cogs
            )
          }
          self.resolveRefresh(at: slot, for: generation, as: .success(value))
          cogs.acknowledge(.asyncCompletionCheck)
        }

        guard let self, let cogs else { return }
        defer { cogs.acknowledge(.asyncCompletionCheck) }
        guard self.acceptsResult(for: generation, at: slot, in: cogs.arenaCore) else { return }
        let row = self.installedRow(for: slot)
        self.activeTasks[row] = nil
        self.activeRunGenerations[row] = nil
      } catch {
        guard let self, let cogs else { return }
        defer { cogs.acknowledge(.asyncCompletionCheck) }
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
            .failure(error, value: self.defaultValue(at: row), hasSucceeded: false)
          case .value(let value):
            .failure(error, value: value, hasSucceeded: true)
          }
        self.publish(
          failure,
          completing: generation,
          named: "failure",
          at: slot,
          key: key,
          in: cogs
        )
        self.resolveRefresh(at: slot, for: generation, as: .failure(error))
      }
    }
  }

  /// Starts the next deferred request after one serial operation terminates.
  private func advanceOrderedScheduler(
    at slot: CogArenaSlot,
    key: CogKey?,
    in core: CogArenaCore,
    cogs: Cogs
  ) {
    let row = installedRow(for: slot)
    switch descriptor.policy {
    case .queue:
      guard !queuedRuns[row].isEmpty else { return }
      let run = queuedRuns[row].removeFirst()
      beginDeferredRun(
        run,
        at: slot,
        key: key,
        requiringPublicationTurn: true,
        in: core,
        cogs: cogs
      )
    case .exhaustLatest:
      guard let run = exhaustCatchUps[row] else { return }
      exhaustCatchUps[row] = nil
      beginDeferredRun(
        run,
        at: slot,
        key: key,
        requiringPublicationTurn: true,
        in: core,
        cogs: cogs
      )
    case .latest, .merged:
      break
    }
  }

  /// Publishes one pending arena status through the turn's scalar source pass.
  func publishPendingStatus(
    at slot: CogArenaSlot,
    revision: UInt32,
    propagatingWith propagation: CogArenaDirtyPropagation
  ) -> Bool {
    _ = installedRow(for: slot)
    return statuses.publishSource(
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
    activeRunGenerations[row] = nil
    queuedRuns[row].removeAll(keepingCapacity: false)
    exhaustCatchUps[row] = nil
    let mergedTasks = Array(activeMergedTasks[row].values)
    activeMergedTasks[row].removeAll(keepingCapacity: false)
    for task in mergedTasks {
      task.cancel()
    }
    if statuses.contains(slot) {
      statuses.remove(at: slot)
    }
    installed[row] = false
    successes[row] = .absent
    defaults[row] = nil
    observationChanges[row] = []
  }

  /// Invalidates and cancels every installed task before context ARC teardown.
  func prepareForContextTeardown() {
    for row in installed.indices where installed[row] {
      resolveRefreshes(at: row, as: .released)
      _ = advanceGeneration(at: row)
      activeTasks[row]?.cancel()
      activeTasks[row] = nil
      activeRunGenerations[row] = nil
      queuedRuns[row].removeAll(keepingCapacity: false)
      exhaustCatchUps[row] = nil
      let mergedTasks = Array(activeMergedTasks[row].values)
      activeMergedTasks[row].removeAll(keepingCapacity: false)
      for task in mergedTasks {
        task.cancel()
      }
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
    let generationIsAccepted =
      switch descriptor.policy {
      case .queue, .exhaustLatest:
        activeRunGenerations[row] == generation
      case .latest:
        generations[row] == generation
      case .merged:
        activeMergedTasks[row][generation] != nil
      }
    guard generationIsAccepted else { return false }
    let flags = arena.flags[row]
    guard !flags.contains(.dirty), !flags.contains(.check) else {
      if descriptor.policy == .merged {
        activeMergedTasks[row].removeValue(forKey: generation)
      } else {
        activeTasks[row] = nil
        activeRunGenerations[row] = nil
      }
      arena.flags[row].remove(.check)
      arena.flags[row].insert(.dirty)
      return false
    }
    return true
  }

  /// Stages one accepted result as its own named graph-owned turn.
  private func publish(
    _ status: CogStatus<Value>,
    completing generation: UInt64,
    named statusName: String,
    at slot: CogArenaSlot,
    key: CogKey?,
    in cogs: Cogs
  ) {
    let row = installedRow(for: slot)
    if descriptor.policy == .merged {
      activeMergedTasks[row].removeValue(forKey: generation)
    } else {
      activeTasks[row] = nil
      activeRunGenerations[row] = nil
    }
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
    activeMergedTasks.append(contentsOf: repeatElement([:], count: missing))
    activeRunGenerations.append(contentsOf: repeatElement(nil, count: missing))
    queuedRuns.append(contentsOf: repeatElement([], count: missing))
    exhaustCatchUps.append(contentsOf: repeatElement(nil, count: missing))
    generations.append(contentsOf: repeatElement(0, count: missing))
    successes.append(contentsOf: repeatElement(.absent, count: missing))
    defaults.append(contentsOf: repeatElement(nil, count: missing))
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
