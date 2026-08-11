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

  /// Declares a source whose nodes all start at the same value.
  init(startingValue: Value, label: CogLabel) {
    self.label = label
    self.start = .constant(startingValue)
  }

  /// Declares a keyed source whose nodes start at a value computed from the
  /// key.
  ///
  /// The closure takes the erased `AnyHashable?` the ref carries rather than a
  /// concrete key type, because this descriptor is deliberately not generic
  /// over the key. ``ManualCogBox`` is the only thing that builds one, and it
  /// wraps the user's typed closure so the erasure never reaches user code.
  init(startingValueForKey: @escaping @MainActor (AnyHashable?) -> Value, label: CogLabel) {
    self.label = label
    self.start = .perKey(startingValueForKey)
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
