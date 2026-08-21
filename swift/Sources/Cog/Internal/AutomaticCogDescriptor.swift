/// The descriptor behind an automatic cog declaration.
///
/// ``Cog`` and ``CogBox`` share this descriptor type. It is generic over the
/// value; the reference carries an erased key (perf §4).
///
/// Every state for the declaration uses the selector stored here.
/// Mutable cache, dependency, Observation, and lifetime bookkeeping remain on
/// the per-context arena row; the descriptor is immutable after
/// declaration construction and is invoked only on the graph's MainActor.
#if !COG_ARENA_COMPACT
@usableFromInline
#endif
internal final class AutomaticCogDescriptor<Value>: CogDescriptor {
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  let label: CogLabel

  /// Whether states of this declaration are releasable when unobserved.
  ///
  /// Synchronous automatic values use `whileObserved` because Cog can recompute
  /// them; the lifetime engine uses this policy when it schedules release.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  let lifetime: CogStateLifetime

  /// Arena context whose keyless location the two fields below memoize.
  ///
  /// Identical in shape, contract, and safety argument to
  /// ``ManualCogDescriptor``'s memo; read the commentary there. The invariant
  /// that carries the most weight for a *automatic* declaration is the second
  /// one: a `whileObserved` automatic state is released as soon as its grace
  /// expires, and the memo must not be able to resurrect it. It cannot,
  /// because the released row advances its occupant generation before the
  /// index is reusable, so the memoized slot stops naming a live occupant.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  internal var memoizedArenaContext: UInt64 = 0

  /// Typed value column this declaration owns inside `memoizedArenaContext`.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  internal var memoizedArenaColumn: CogArenaValueColumn<Value>?

  /// Exact slot lifetime of this declaration's **keyless** state there.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  internal var memoizedArenaSlot: CogArenaSlot?

  /// How a state of this declaration computes its value.
  ///
  /// Explicit `@MainActor` keeps the closure isolated under any caller default
  /// (§1.2, §2.5, §7). Synchronous selectors cannot throw in v1, which makes a
  /// throwing declaration fail to compile (`DECL-12`).
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  internal let selector: @MainActor (Reader<Value>, CogKey?) -> Value

  /// Whether two computed values count as the same state, or `nil` when every
  /// recomputation must conservatively count as a change.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  internal let equals: (@MainActor (Value, Value) -> Bool)?

  /// Declares an automatic value computed by `selector`.
  init(
    selector: @escaping @MainActor (Reader<Value>, CogKey?) -> Value,
    equals: (@MainActor (Value, Value) -> Bool)?,
    lifetime: CogStateLifetime = .whileObserved(grace: nil),
    label: CogLabel
  ) {
    self.label = label
    self.lifetime = lifetime
    self.selector = selector
    self.equals = equals
  }

  /// Runs the selector once for the state `reader` belongs to.
  ///
  /// Keyless and keyed declarations share this call site. The state must have
  /// installed its tracking scope and active-computation marker first; this
  /// descriptor deliberately cannot start settlement or publish a result.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  func compute(_ reader: Reader<Value>, key: CogKey?) -> Value {
    selector(reader, key)
  }

  /// Whether a recomputation is equivalent to the state's cached value.
  ///
  /// The public declaration overloads install `==`, preserve a custom rule,
  /// or leave the comparator absent so an opaque value assumes change. This
  /// comparison runs after dependency capture but before the state records its
  /// final versions, within the enclosing computation barrier.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  func valuesAreEqual(_ oldValue: Value, _ newValue: Value) -> Bool {
    equals?(oldValue, newValue) ?? false
  }

  /// The keyless arena location memoized for `context`, if one is filed.
  ///
  /// The caller still has to prove the slot is live; see the manual
  /// descriptor's ``ManualCogDescriptor/memoizedArenaLocation(in:)``.
  ///
  /// - Parameter context: The reading context's ``CogArenaCore/contextIdentity``.
  /// - Returns: The declaration's keyless slot and typed column in that exact
  ///   context, or `nil` when this declaration has not been resolved there.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  func memoizedArenaLocation(
    in context: UInt64
  ) -> (slot: CogArenaSlot, column: CogArenaValueColumn<Value>)? {
    guard context == memoizedArenaContext,
      let slot = memoizedArenaSlot,
      let column = memoizedArenaColumn
    else { return nil }
    return (slot, column)
  }

  /// Files the keyless location this declaration resolved to in `context`.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  func memoizeArenaLocation(
    slot: CogArenaSlot,
    column: CogArenaValueColumn<Value>,
    in context: UInt64
  ) {
    memoizedArenaContext = context
    memoizedArenaColumn = column
    memoizedArenaSlot = slot
  }

  /// Drops the memo when, and only when, it belongs to `context`.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  func forgetMemoizedArenaLocation(in context: UInt64) {
    guard context == memoizedArenaContext else { return }
    memoizedArenaContext = 0
    memoizedArenaColumn = nil
    memoizedArenaSlot = nil
  }

  // Written out, and `nonisolated`, per the rule at the top of
  // `CogDescriptor.swift`. Removing it crashes the release build.
  nonisolated deinit {}
}
