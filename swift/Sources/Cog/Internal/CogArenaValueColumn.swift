/// Descriptor-owned concrete values indexed by one context's arena slots.
///
/// Each descriptor creates one column of its `Value` type inside an arena
/// context. Rows belonging to other descriptors remain empty, so a normal read
/// returns concrete `Value` without `Any`, existential dispatch, or per-state
/// objects. Current and pending cells are separate to preserve the turn
/// boundary and writer read-your-writes semantics.
///
/// The outer optional in each cell records storage presence. If `Value` is
/// itself optional, `.some(.none)` is a stored or staged domain `nil`, while
/// outer `.none` means this descriptor has no value at that arena row.
@MainActor
#if !COG_ARENA_COMPACT
@usableFromInline
#endif
internal final class CogArenaValueColumn<Value> {
  /// Scalar arena whose slot lifetimes govern every cell in this column.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  internal let arena: CogArenaStorage

  /// Latest completed value at each occupied row for this descriptor.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  internal var currentValues: ContiguousArray<Value?> = []

  /// Final value staged by the accumulating turn at each touched row.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  internal var pendingValues: ContiguousArray<Value?> = []

  /// Descriptor-level equality rule, or `nil` when every turn changes.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  internal let equals: (@MainActor (Value, Value) -> Bool)?

  /// Creates the typed column belonging to one descriptor in `arena`.
  ///
  /// The comparator is installed once from the descriptor. Reads and staging
  /// therefore stay concrete; only publication invokes this stored function.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  init(
    in arena: CogArenaStorage,
    equals: (@MainActor (Value, Value) -> Bool)? = nil
  ) {
    self.arena = arena
    self.equals = equals
  }

  /// Installs the first current value for an allocated arena slot.
  ///
  /// Sparse columns grow through the slot's row and leave intervening rows
  /// empty for other descriptors. Reinstalling a live descriptor row is a
  /// lifecycle error; callers must remove it before the arena slot is released.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  func insert(_ value: Value, at slot: CogArenaSlot) {
    let row = arena.index(of: slot)
    ensureStorage(through: row)
    guard case .none = currentValues[row], case .none = pendingValues[row] else {
      fatalError("Cog tried to install two values in one descriptor column row.")
    }
    currentValues[row] = .some(value)
  }

  /// Reads the latest value published by a completed turn.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  func current(at slot: CogArenaSlot) -> Value {
    let row = installedRow(for: slot)
    guard case .some(let value) = currentValues[row] else {
      fatalError("Cog lost an installed arena column value.")
    }
    return value
  }

  /// Returns the completed value when this descriptor has published one.
  ///
  /// A cold automatic row legitimately has no cell yet. The returned outer
  /// optional preserves a published optional domain `nil` as `.some(.none)`.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  func storedValue(at slot: CogArenaSlot) -> Value? {
    let row = arena.index(of: slot)
    guard row < currentValues.count else { return .none }
    return currentValues[row]
  }

  /// Reads this turn's staged value when present, otherwise the current value.
  ///
  /// Writers use this path so multiple mutations in one accumulating turn see
  /// their own final staged state without publishing it to ordinary readers.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  func writerValue(at slot: CogArenaSlot) -> Value {
    let row = installedRow(for: slot)
    if case .some(let pending) = pendingValues[row] {
      return pending
    }
    guard case .some(let current) = currentValues[row] else {
      fatalError("Cog lost an installed arena column value.")
    }
    return current
  }

  /// Replaces the final value staged for this slot by the accumulating turn.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  func stage(_ value: Value, at slot: CogArenaSlot) {
    let row = installedRow(for: slot)
    pendingValues[row] = .some(value)
  }

  /// Whether the accumulating turn currently owns a staged cell for `slot`.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  func hasPendingValue(at slot: CogArenaSlot) -> Bool {
    let row = installedRow(for: slot)
    if case .some = pendingValues[row] {
      return true
    }
    return false
  }

  /// Consumes one pending cell and publishes it when the descriptor says it changed.
  ///
  /// Equality compares the latest completed value with only the final staged
  /// value. Equal reversion still clears pending storage but returns `false`,
  /// telling the caller not to advance versions or propagate dirty flags.
  @discardableResult
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  func publish(at slot: CogArenaSlot) -> Bool {
    let row = installedRow(for: slot)
    guard case .some(let pending) = pendingValues[row] else { return false }
    pendingValues[row] = .none

    guard case .some(let current) = currentValues[row] else {
      fatalError("Cog lost an installed arena column value.")
    }
    guard !(equals?(current, pending) ?? false) else { return false }

    currentValues[row] = .some(pending)
    return true
  }

  /// Publishes one manual source value and pushes its arena invalidation wave.
  ///
  /// The supplied revision belongs to the enclosing turn. A real change marks
  /// the source current at that revision before any consumer sees DIRTY or
  /// CHECK. An equal final staged value consumes pending storage but preserves
  /// both versions and sends no propagation.
  @discardableResult
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  func publishSource(
    at slot: CogArenaSlot,
    revision: UInt32,
    propagatingWith propagation: CogArenaDirtyPropagation
  ) -> Bool {
    guard propagation.belongs(to: arena) else {
      fatalError("Cog tried to propagate a value through another arena context.")
    }
    guard hasPendingValue(at: slot) else { return false }

    let row = arena.index(of: slot)
    guard revision > arena.checkedAt[row] else {
      fatalError("Cog tried to publish an arena source with a stale graph revision.")
    }
    guard publish(at: slot) else { return false }
    guard !arena.flags[row].contains(.computing) else {
      fatalError("Cog tried to publish an arena source while it was computing.")
    }

    arena.changedAt[row] = revision
    arena.checkedAt[row] = revision
    arena.flags[row].remove(.check)
    arena.flags[row].remove(.dirty)
    propagation.invalidateSubscribers(of: slot)
    return true
  }

  #if DEBUG
  /// Publishes one equality-approved testing seed without a pending turn cell.
  ///
  /// The caller compares the candidate before advancing the context revision,
  /// so this path must install the supplied value exactly once and must not run
  /// the descriptor comparator again. It marks arena subscribers for later
  /// settlement but does not flush reactions, boundaries, or debug history.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  func publishSeed(
    _ value: Value,
    at slot: CogArenaSlot,
    revision: UInt32,
    propagatingWith propagation: CogArenaDirtyPropagation
  ) {
    guard propagation.belongs(to: arena) else {
      fatalError("Cog tried to propagate a testing seed through another arena context.")
    }
    let row = installedRow(for: slot)
    guard case .none = pendingValues[row] else {
      fatalError("Cog tried to seed an arena source with a pending turn value.")
    }
    guard revision > arena.checkedAt[row] else {
      fatalError("Cog tried to publish an arena testing seed with a stale graph revision.")
    }
    guard !arena.flags[row].contains(.computing) else {
      fatalError("Cog tried to seed an arena source while it was computing.")
    }

    currentValues[row] = .some(value)
    arena.changedAt[row] = revision
    arena.checkedAt[row] = revision
    arena.flags[row].remove(.check)
    arena.flags[row].remove(.dirty)
    propagation.invalidateSubscribers(of: slot)
  }
  #endif

  /// Clears both value cells before the owning arena slot is released.
  ///
  /// Clearing first releases reference-valued payloads under the context's
  /// MainActor confinement and prevents a later occupant of the same row from
  /// observing stale pending state.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  func remove(at slot: CogArenaSlot) {
    let row = installedRow(for: slot)
    currentValues[row] = .none
    pendingValues[row] = .none
  }

  /// Whether this descriptor currently owns a value at the exact slot lifetime.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  func contains(_ slot: CogArenaSlot) -> Bool {
    guard arena.contains(slot) else { return false }
    let row = Int(slot.index)
    guard row < currentValues.count else { return false }
    if case .some = currentValues[row] {
      return true
    }
    return false
  }

  /// Extends both optional-backed arrays in lockstep through `row`.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  func ensureStorage(through row: Int) {
    guard row >= currentValues.count else { return }
    let missing = row + 1 - currentValues.count
    currentValues.append(contentsOf: repeatElement(.none, count: missing))
    pendingValues.append(contentsOf: repeatElement(.none, count: missing))
  }

  /// Resolves an exact live slot and verifies this descriptor owns its row.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  func installedRow(for slot: CogArenaSlot) -> Int {
    let row = arena.index(of: slot)
    guard row < currentValues.count else {
      fatalError("Cog tried to use an arena slot outside its descriptor column.")
    }
    guard case .some = currentValues[row] else {
      fatalError("Cog tried to use an empty descriptor column row.")
    }
    return row
  }

  // Written out, and `nonisolated`, because generic classes under the
  // package's MainActor default otherwise crash the pinned release optimizer.
  nonisolated deinit {}
}
