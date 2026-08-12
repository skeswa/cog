/// The descriptor behind a manual source declaration.
///
/// One descriptor stands behind one ``ManualCog`` declaration *and* one
/// ``ManualCogBox`` declaration. It is generic over the value but not over a
/// key: the correctness build spells keys as an inline `AnyHashable?` on the
/// ref (perf §4), so a keyless declaration and a keyed box share this one
/// descriptor kind. That sharing is what makes `box[key]` cheap — a box holds
/// one descriptor for every key it will ever be asked for, and a keyed ref is
/// that descriptor plus the key (§2.3).
internal final class ManualCogDescriptor<Value>: CogDescriptor {
  let label: CogLabel

  /// Manual state stays resident until its context ends by default.
  ///
  /// Releasing a source would otherwise silently restore its starting value.
  /// The later manual lifetime opt-in may select `whileObserved`, but every
  /// ordinary source and box uses this app-lifetime default.
  let lifetime: CogNodeLifetime

  /// Where a node of this declaration gets its first value.
  ///
  /// The starting value lives on the descriptor because the declaration is
  /// what knows it. Nodes appear lazily per descriptor and key, so whichever
  /// node appears first — in the app context, or in a test or preview
  /// runtime — has to start somewhere, and it cannot ask a turn that never
  /// happened.
  ///
  /// Private because nothing outside this file should care which of the two
  /// forms a declaration used; callers ask ``startingValue(forKey:)`` for the
  /// value of one node and get the same answer either way.
  private let start: ManualCogStartingValue<Value>

  /// Whether two values count as the same state, or `nil` when every write
  /// must conservatively count as a change.
  ///
  /// The declaration owns this policy because every live node for it — across
  /// keys and isolated contexts — follows the same rule. `ManualCog` and
  /// `ManualCogBox` install `==` for an `Equatable` value, preserve an
  /// explicit `equals:` closure, or leave this nil for an opaque value.
  private let equals: (@MainActor (Value, Value) -> Bool)?

  /// Declares a source whose nodes all start at the same value.
  init(
    startingValue: Value,
    equals: (@MainActor (Value, Value) -> Bool)?,
    lifetime: CogNodeLifetime = .app,
    label: CogLabel
  ) {
    self.label = label
    self.lifetime = lifetime
    self.start = .constant(startingValue)
    self.equals = equals
  }

  /// Declares a keyed source whose nodes start at a value computed from the
  /// key.
  ///
  /// The closure takes the erased `AnyHashable?` the ref carries rather than a
  /// concrete key type, because this descriptor is deliberately not generic
  /// over the key. ``ManualCogBox`` is the only thing that builds one, and it
  /// wraps the user's typed closure so the erasure never reaches user code.
  init(
    startingValueForKey: @escaping @MainActor (AnyHashable?) -> Value,
    equals: (@MainActor (Value, Value) -> Bool)?,
    lifetime: CogNodeLifetime = .app,
    label: CogLabel
  ) {
    self.label = label
    self.lifetime = lifetime
    self.start = .perKey(startingValueForKey)
    self.equals = equals
  }

  /// The value the node for `key` holds before anything writes to it.
  ///
  /// - Parameter key: The node's key, or `nil` for a keyless declaration.
  func startingValue(forKey key: AnyHashable?) -> Value {
    switch start {
    case .constant(let value):
      return value
    case .perKey(let makeStartingValue):
      return makeStartingValue(key)
    }
  }

  /// Whether a staged value is equal to the source's current value.
  ///
  /// No comparator means "assume changed," so this method deliberately
  /// returns false rather than trying to discover `Equatable` dynamically.
  /// The public declaration overloads make that choice statically and keep
  /// the hot flush path concrete.
  func valuesAreEqual(_ oldValue: Value, _ newValue: Value) -> Bool {
    equals?(oldValue, newValue) ?? false
  }

  // Written out, and `nonisolated`, per the rule at the top of
  // `CogDescriptor.swift`. Removing it crashes the release build.
  nonisolated deinit {}
}

/// The two forms a manual declaration's starting value can take.
///
/// An enum rather than one stored closure so that the common form stays free:
/// a constant costs no closure context and no call, which matters because an
/// app declares many sources and most of them are constants. The keyed form
/// pays for itself only where it is used.
///
/// This is not a public spelling. ``ManualCog`` and ``ManualCogBox`` choose
/// the case from the initializer the declaration used, so a user picks between
/// the two by writing `(0)` or `{ key in ... }`.
internal enum ManualCogStartingValue<Value> {
  /// Every node of the declaration starts at this value.
  case constant(Value)

  /// Each node starts at what this returns for its own key.
  case perKey(@MainActor (AnyHashable?) -> Value)
}
