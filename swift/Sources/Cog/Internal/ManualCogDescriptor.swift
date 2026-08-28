/// The descriptor behind a manual source declaration.
///
/// ``Cog/Manual`` and ``CogBox/Manual`` share this descriptor type. It is
/// generic over the value; the reference carries an erased key. A keyed
/// reference is one descriptor plus its key (§2.3, perf §4).
/// The immutable descriptor is shared across contexts; each context owns the
/// current and staged value for each descriptor-and-key identity separately.
#if !COG_ARENA_COMPACT
@usableFromInline
#endif
internal final class ManualCogDescriptor<Value>: CogDescriptor {
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  let label: CogLabel

  /// Manual state stays resident until its context ends by default.
  ///
  /// Releasing a source would reset it to its starting value. A later manual
  /// lifetime option may select `whileObserved`.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  let lifetime: CogStateLifetime

  /// Arena context whose keyless location the two fields below memoize.
  ///
  /// Zero means "no memo". A context identity is process-unique and strictly
  /// monotonic (``CogArenaCore/contextIdentity``), so a memo written for one
  /// `Cogs` can never be mistaken for another's even after that `Cogs` has been
  /// deallocated and a new one has taken its address. That is the whole safety
  /// argument for reading the two fields below without revalidating them
  /// against the context's own descriptor registry.
  ///
  /// The descriptor is otherwise immutable. These fields cache three costs:
  /// the descriptor lookup, a checked column downcast, and the slot lookup.
  /// Without them, every keyless read, write, and lifetime renewal would pay
  /// all three. Like other graph fields, they change only on the MainActor.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  internal var memoizedArenaContext: UInt64 = 0

  /// Typed value column this declaration owns inside `memoizedArenaContext`.
  ///
  /// Retained rather than held unowned so a torn-down context can never be
  /// read through a dangling pointer. The retention is bounded: at most one
  /// column per declaration, replaced the first time the declaration is used
  /// with another context, and cleared outright by that context's teardown.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  internal var memoizedArenaColumn: CogArenaValueColumn<Value>?

  /// Exact slot lifetime of this declaration's **keyless** state there.
  ///
  /// Keyed states are deliberately excluded: one declaration names a family of
  /// them, and a single-entry memo would thrash. `box[key]` therefore keeps the
  /// ordinary identity lookup.
  ///
  /// The slot carries its occupant generation, and a released row always
  /// advances that generation before it can be reused, so a caller that finds
  /// the memo stale learns it from ``CogArenaStorage/contains(_:)`` rather than
  /// from any invalidation hook.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  internal var memoizedArenaSlot: CogArenaSlot?

  /// Where a state of this declaration gets its first value.
  ///
  /// The descriptor stores either one constant or a per-key closure. Callers
  /// use ``startingValue(forKey:)`` without knowing which form was declared.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  internal let start: ManualCogStartingValue<Value>

  /// Whether two values count as the same state, or `nil` when every write
  /// must conservatively count as a change.
  ///
  /// All keys and contexts use the declaration's rule. `Equatable` overloads
  /// install `==`; opaque values leave this `nil`.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  internal let equals: (@MainActor (Value, Value) -> Bool)?

  /// Declares a source whose states each start at a freshly produced value.
  ///
  /// `startingValue` runs once per state rather than once per declaration, so
  /// two contexts and two keys of one box never share the object it returns.
  init(
    startingValue: @escaping @MainActor () -> Value,
    equals: (@MainActor (Value, Value) -> Bool)?,
    lifetime: CogStateLifetime = .app,
    label: CogLabel
  ) {
    self.label = label
    self.lifetime = lifetime
    self.start = .shared(startingValue)
    self.equals = equals
  }

  /// Declares a keyed source whose states start at a value computed from the
  /// key.
  ///
  /// ``CogBox/Manual`` wraps the typed closure before storing it here, so key
  /// erasure never reaches user code.
  init(
    startingValueForKey: @escaping @MainActor (CogKey?) -> Value,
    equals: (@MainActor (Value, Value) -> Bool)?,
    lifetime: CogStateLifetime = .app,
    label: CogLabel
  ) {
    self.label = label
    self.lifetime = lifetime
    self.start = .perKey(startingValueForKey)
    self.equals = equals
  }

  /// The value the state for `key` holds before anything writes to it.
  ///
  /// The context invokes this once when it lazily creates that exact state.
  /// Repeated reads and writes use the resident value and never rerun the
  /// closure; a `whileObserved(resetToInitial:)` state that has been released
  /// runs it again on the read that recreates it, which is what makes that
  /// reset produce a fresh value rather than the released one.
  ///
  /// - Parameter key: The state's key, or `nil` for a keyless declaration.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  func startingValue(forKey key: CogKey?) -> Value {
    switch start {
    case .shared(let makeStartingValue):
      return makeStartingValue()
    case .perKey(let makeStartingValue):
      return makeStartingValue(key)
    }
  }

  /// Whether a staged value is equal to the source's current value.
  ///
  /// Without a comparator, every write counts as changed. Public overloads
  /// choose this statically instead of discovering `Equatable` at runtime.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  func valuesAreEqual(_ oldValue: Value, _ newValue: Value) -> Bool {
    equals?(oldValue, newValue) ?? false
  }

  /// The keyless arena location memoized for `context`, if one is filed.
  ///
  /// The caller must still prove the slot is live. The memo has no invalidation
  /// hook of its own. See ``memoizedArenaSlot``.
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
  ///
  /// Writing a memo for a different context replaces the previous one whole,
  /// which is what keeps a declaration shared by a test, a preview, and an app
  /// from retaining more than one context's column at a time.
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
  ///
  /// Release and teardown both call this. Guarding on the context matters:
  /// one context tearing down must not evict a memo another context is still
  /// using, which would be a silent slowdown rather than a visible failure.
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

/// The two forms a manual declaration's starting value can take.
///
/// Both cases store closures because a descriptor outlives every state it names.
/// Storing one value would share it across contexts, box keys, and recreated
/// `whileObserved` states. Reference values would then share one object (§3.1).
/// Public initializers select the case from
/// `{ 0 }` or `{ key in ... }`.
///
/// Both are MainActor-isolated because lazy state creation is graph work; the
/// erased key adapter restores the public key type before user code observes
/// it.
#if !COG_ARENA_COMPACT
@usableFromInline
#endif
internal enum ManualCogStartingValue<Value> {
  /// Each state starts at what this returns, ignoring any key.
  case shared(@MainActor () -> Value)

  /// Each state starts at what this returns for its own key.
  case perKey(@MainActor (CogKey?) -> Value)
}
