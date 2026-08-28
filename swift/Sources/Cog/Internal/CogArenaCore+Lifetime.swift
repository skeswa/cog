// MARK: - Observation and lifetime

/// Cold Observation-boundary ownership and `whileObserved` lifetime release.
///
/// Boundary objects and grace-period tasks remain outside hot scalar storage.
/// Exact slot and sleeper generations reject both row reuse and stale deadlines
/// before this extension removes a value and its disconnected dependency chain.
extension CogArenaCore {
  /// Records one ordinary UI value access on a slot's stable boundary.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  func accessObservationBoundary(for slot: CogArenaSlot) {
    ensureObservationBoundary(for: slot).accessValue()
  }

  /// Returns an existing boundary after validating its exact slot lifetime.
  ///
  /// Unlike ``ensureObservationBoundary(for:)``, this lookup never creates or
  /// pins a boundary. Debug seed uses it so setup cannot make an unread state
  /// pay the permanent UI-lifetime cost merely to remember a deferred change.
  func observationBoundary(for slot: CogArenaSlot) -> CogObservationBoundary? {
    let row = arena.index(of: slot)
    let existingIndex = arena.boundary[row]
    guard existingIndex != CogArenaStorage.noIndex else { return nil }
    guard existingIndex >= 0, Int(existingIndex) < observationEntries.count else {
      fatalError("Cog found an arena row with an invalid Observation boundary index.")
    }
    let entry = observationEntries[Int(existingIndex)]
    guard entry.slot == slot else {
      fatalError("Cog found an Observation boundary attached to another arena slot lifetime.")
    }
    return entry.boundary
  }

  /// Returns the slot's existing boundary or creates its sole cold entry.
  ///
  /// The row stores only an `Int32` index. The ordered table owns the registrar
  /// object and exact slot generation, so graph walks never load a reference
  /// merely because a different row crossed the UI boundary.
  func ensureObservationBoundary(for slot: CogArenaSlot) -> CogObservationBoundary {
    let row = arena.index(of: slot)
    if let existing = observationBoundary(for: slot) { return existing }

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
  func incrementLease(on slot: CogArenaSlot) {
    let row = arena.index(of: slot)
    guard case .whileObserved = descriptorRecord(forRow: row).lifetime else { return }
    cancelPendingLifetimeRelease(on: slot)
    guard arena.leaseCount[row] < UInt32.max else {
      fatalError("A Cog arena state's durable lifetime lease count overflowed.")
    }
    arena.leaseCount[row] += 1
  }

  /// Removes one durable owner and begins grace at the exact zero transition.
  func decrementLease(on slot: CogArenaSlot, schedulingIn cogs: Cogs) {
    decrementLeaseWithoutScheduling(on: slot)
    let row = arena.index(of: slot)
    guard arena.leaseCount[row] == 0 else { return }
    guard arena.boundary[row] == CogArenaStorage.noIndex else { return }
    scheduleLifetimeReleaseIfUnobserved(slot, in: cogs)
  }

  /// Removes one owner without creating graph work during context teardown.
  func decrementLeaseWithoutScheduling(on slot: CogArenaSlot) {
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
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  func scheduleLifetimeReleaseIfUnobserved(
    _ slot: CogArenaSlot,
    in cogs: Cogs
  ) {
    let row = arena.index(of: slot)
    let lifetime = withDescriptorRecord(forRow: row) { $0.lifetime }
    guard case .whileObserved(let declaredGrace) = lifetime else { return }
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
  func releaseValueStateIfEligible(
    _ slot: CogArenaSlot,
    lifetimeGeneration: UInt64,
    in cogs: Cogs
  ) {
    defer { cogs.acknowledge(.lifetimeReleaseCheck) }

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
    guard arena.subs[row] == .none else { return }

    releaseUnobservedClosure(startingAt: slot)
    cogs.acknowledge(.lifetimeRelease)
  }

  /// Releases the root and newly disconnected unobserved dependencies.
  ///
  /// A dependency with a future deadline keeps that independent grace. One
  /// whose own deadline already elapsed while subscribed has no pending token
  /// and leaves in this same iterative cascade, so internal edges never grant a
  /// second grace period.
  func releaseUnobservedClosure(startingAt root: CogArenaSlot) {
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
      guard arena.subs[row] == .none else { continue }
      guard slot == root || lifetimeEntries[row].pendingGeneration == nil else { continue }

      releaseValueState(slot, appendingDependenciesTo: &candidates)
    }
  }

  /// Removes one exact value row from topology, typed storage, and identity.
  ///
  /// Dependencies are captured before edge removal so newly unreferenced
  /// upstream states can join the same lifetime cascade. Every owner clears
  /// before the scalar index is returned for reuse.
  func releaseValueState(
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
    guard arena.subs[row] == .none else {
      fatalError("Cog tried to release an arena state with live subscribers.")
    }
    guard !arena.flags[row].contains(.computing), !arena.flags[row].contains(.touched) else {
      fatalError("Cog tried to release an arena state during active graph work.")
    }

    var cursor = arena.deps[row]
    while cursor != .none {
      let dependency = edges.edge(at: cursor)
      guard dependency.sub == slot.index else {
        fatalError("Cog found another consumer's edge in an arena release list.")
      }
      let producerRow = liveRow(dependency.dep)
      candidates.append(
        CogArenaSlot(index: dependency.dep, generation: arena.generation[producerRow])
      )
      cursor = dependency.nextDep
    }

    let key = record.key(at: row)
    let identity = CogStateIdentity(descriptor: record.identity, key: key)
    cancelPendingLifetimeRelease(on: slot)
    edges.removeDependencySuffix(of: slot, after: .none, in: arena)
    record.removeValue(slot)
    record.removeKey(at: row)
    // Belt and braces, and only for the one state the memo can name. The
    // memoized slot would already fail its liveness check once this row's
    // generation advances below, so dropping it here is not what makes the
    // memo correct — it is what keeps a released declaration from pinning
    // this context's column after the state itself is gone.
    if key == nil {
      record.forgetMemoizedLocation(contextIdentity)
    }
    guard slots.removeValue(forKey: identity) == slot else {
      fatalError("Cog removed a different arena slot from state identity storage.")
    }
    arena.release(slot)
  }

  /// Cancels a sleeper before a lease, release, or context teardown can race it.
  func cancelPendingLifetimeRelease(on slot: CogArenaSlot) {
    let row = arena.index(of: slot)
    _ = advanceLifetimeReleaseGeneration(at: row)
    lifetimeEntries[row].pendingGeneration = nil
    lifetimeEntries[row].task?.cancel()
    lifetimeEntries[row].task = nil
  }

  /// Advances a row's deadline token without permitting stale-token wraparound.
  func advanceLifetimeReleaseGeneration(at row: Int) -> UInt64 {
    guard lifetimeEntries[row].generation < UInt64.max else {
      fatalError("A Cog arena state's lifetime release generation overflowed.")
    }
    lifetimeEntries[row].generation += 1
    return lifetimeEntries[row].generation
  }

  /// Installs empty cold metadata for a newly allocated value-row occupant.
  func resetLifetimeEntry(at row: Int) {
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
    for record in records {
      let record = record.takeUnretainedValue()
      record.prepareForContextTeardown()
      // Declarations outlive contexts. Evicting here keeps a `static let`
      // declaration from retaining this graph's typed column — and the values
      // in it — after the context that owned them is gone. The memo would
      // still be *correct* without this, because no later context can match
      // this one's identity; it would merely leak one column per declaration.
      record.forgetMemoizedLocation(contextIdentity)
    }
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
  ///
  /// "Without retaining" holds for the `Unmanaged` load, but the returned
  /// strong reference still costs the caller one retain/release pair. The
  /// scoped form below avoids that pair; prefer it on per-turn and per-node
  /// paths.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  func descriptorRecord(forRow row: Int) -> CogArenaDescriptorRecord {
    let descriptorIndex = arena.descriptor[row]
    guard descriptorIndex >= 0, Int(descriptorIndex) < records.count else {
      fatalError("Cog found a live arena row without descriptor dispatch.")
    }
    return records[Int(descriptorIndex)].takeUnretainedValue()
  }

  /// Runs `body` with one row's descriptor record borrowed, never retained.
  ///
  /// The context's identity table owns every record for as long as the
  /// context lives, and the publish, settle, notify, and reaction walks that
  /// call this run synchronously on the MainActor while it does — a release
  /// cascade runs from a sleeper task or teardown, never from inside one of
  /// these walks — so the reference is guaranteed for `body`'s whole scope.
  /// This is issue #373's route C at the record seam: the returning accessor
  /// above pays one retain/release pair per call, and the walks pay that per
  /// settled node.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  func withDescriptorRecord<Result>(
    forRow row: Int,
    _ body: (CogArenaDescriptorRecord) -> Result
  ) -> Result {
    let descriptorIndex = arena.descriptor[row]
    guard descriptorIndex >= 0, Int(descriptorIndex) < records.count else {
      fatalError("Cog found a live arena row without descriptor dispatch.")
    }
    return records[Int(descriptorIndex)]._withUnsafeGuaranteedRef(body)
  }

  #if DEBUG
  /// Resolves one descriptor dispatch index while materializing debug history.
  func descriptorRecord(at rawIndex: Int32) -> CogArenaDescriptorRecord {
    guard rawIndex >= 0, Int(rawIndex) < records.count else {
      fatalError("Cog found an invalid arena descriptor index in debug history.")
    }
    return records[Int(rawIndex)].takeUnretainedValue()
  }
  #endif
}
