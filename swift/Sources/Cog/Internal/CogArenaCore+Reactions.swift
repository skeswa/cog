// MARK: - Reactions

/// Reaction terminal allocation, dependency capture, leasing, and settlement.
///
/// A reaction remains closure-backed at the context boundary while this
/// extension gives it a scalar terminal in the same edge topology as automatic
/// values. Its buffers retain their high-water capacity across runs.
extension CogArenaCore {
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
  /// Nested automatic settlement temporarily pushes selector captures above this
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

    var cursor = arena.deps[liveRow(reaction.index)]
    while cursor != .none {
      let dependency = edges.edge(at: cursor)
      guard dependency.sub == reaction.index else {
        fatalError("Cog found another consumer's edge in an arena reaction lease list.")
      }
      let producerRow = liveRow(dependency.dep)
      if case .whileObserved = withDescriptorRecord(forRow: producerRow, { $0.lifetime }) {
        let producer = CogArenaSlot(
          index: dependency.dep,
          generation: arena.generation[producerRow]
        )
        if !scratch.contains(producer) {
          scratch.append(producer)
        }
      }
      cursor = dependency.nextDep
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
  /// automatic recomputation may recapture other lists in the shared edge pool.
  /// Equal recomputations leave their older `changedAt`, allowing this terminal
  /// to backdate and stay quiet exactly like an ordinary automatic consumer.
  func settleReactionDependencies(_ reaction: CogArenaSlot, in cogs: Cogs) -> Bool {
    let reactionRow = requireReactionRow(reaction)
    guard needsSettlement(reactionRow) else { return false }
    guard reactionPullRoots.isEmpty else {
      fatalError("Cog tried to reenter arena reaction dependency settlement.")
    }
    defer { reactionPullRoots.removeAll(keepingCapacity: true) }

    var cursor = arena.deps[liveRow(reaction.index)]
    while cursor != .none {
      let dependency = edges.edge(at: cursor)
      guard dependency.sub == reaction.index else {
        fatalError("Cog found another consumer's edge in an arena reaction list.")
      }
      let producerRow = liveRow(dependency.dep)
      if needsSettlement(producerRow) {
        guard withDescriptorRecord(forRow: producerRow, { $0.kind }) != .manual else {
          fatalError("Cog found an unsettled manual source behind an arena reaction.")
        }
        reactionPullRoots.append(
          CogArenaSlot(index: dependency.dep, generation: arena.generation[producerRow])
        )
      }
      cursor = dependency.nextDep
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
    guard arena.subs[liveRow(reaction.index)] == .none else {
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
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  func read<Value>(
    _ valueReference: Cog<Value>.Manual,
    for consumer: CogArenaSlot
  ) -> Value {
    requireTracking(consumer)
    let producer = manualLocation(for: valueReference)
    recordDependency(from: consumer, on: producer.slot)
    return producer.column.current(at: producer.slot)
  }

  /// Pulls, reads, and records one automatic dependency for the active selector.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  func read<Value>(
    _ valueReference: Cog<Value>,
    for consumer: CogArenaSlot,
    in cogs: Cogs
  ) -> Value {
    requireTracking(consumer)
    let producer = automaticLocation(for: valueReference)
    settle(producer.slot, in: cogs)
    requireTracking(consumer)
    recordDependency(from: consumer, on: producer.slot)
    return producer.column.current(at: producer.slot)
  }

  /// Pulls, reads, and records one async status dependency for an arena consumer.
  func readAsyncStatus<Value>(
    descriptor: AsyncCogDescriptor<Value>,
    key: CogKey?,
    for consumer: CogArenaSlot,
    in cogs: Cogs
  ) -> CogStatus<Value> {
    requireTracking(consumer)
    let producer = asyncLocation(descriptor: descriptor, key: key)
    settle(producer.slot, in: cogs)
    requireTracking(consumer)
    recordDependency(from: consumer, on: producer.slot)
    return producer.column.status(at: producer.slot)
  }

  /// Previous completed value of the active automatic selector, if one exists.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  func previousValue<Value>(for consumer: CogArenaSlot, as: Value.Type) -> Value? {
    requireTracking(consumer)
    let row = arena.index(of: consumer)
    return withDescriptorRecord(forRow: row) { record in
      guard let column = record.column as? CogArenaValueColumn<Value> else {
        fatalError("Cog restored an arena selector through the wrong typed value column.")
      }
      return column.storedValue(at: consumer)
    }
  }

  /// Requires `consumer` to own the innermost active dependency capture.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  func requireTracking(_ consumer: CogArenaSlot) {
    guard captures.last?.consumer == consumer else {
      fatalError("A Cog reader is valid only inside the selector run that handed it out.")
    }
  }

  /// Resolves a live descriptor-less row reserved for one reaction terminal.
  func requireReactionRow(_ reaction: CogArenaSlot) -> Int {
    let row = arena.index(of: reaction)
    guard arena.descriptor[row] == CogArenaStorage.noIndex else {
      fatalError("Cog tried to use a value-state row as an arena reaction terminal.")
    }
    guard arena.boundary[row] == CogArenaStorage.noIndex else {
      fatalError("Cog found an Observation boundary on an arena reaction terminal.")
    }
    return row
  }
}
