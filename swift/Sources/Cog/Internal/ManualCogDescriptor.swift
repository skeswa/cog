/// The descriptor behind a manual source declaration.
///
/// ``ManualCog`` and ``ManualCogBox`` share this descriptor type. It is
/// generic over the value; the reference carries an erased key. A keyed
/// reference is one descriptor plus its key (§2.3, perf §4).
/// The immutable descriptor is shared across contexts; each context owns the
/// current and staged value for each descriptor-and-key identity separately.
internal final class ManualCogDescriptor<Value>: CogDescriptor {
  let label: CogLabel

  /// Manual state stays resident until its context ends by default.
  ///
  /// Releasing a source would reset it to its starting value. A later manual
  /// lifetime option may select `whileObserved`.
  let lifetime: CogStateLifetime

  /// Where a state of this declaration gets its first value.
  ///
  /// The descriptor stores either one constant or a per-key closure. Callers
  /// use ``startingValue(forKey:)`` without knowing which form was declared.
  private let start: ManualCogStartingValue<Value>

  /// Whether two values count as the same state, or `nil` when every write
  /// must conservatively count as a change.
  ///
  /// All keys and contexts use the declaration's rule. `Equatable` overloads
  /// install `==`; opaque values leave this `nil`.
  private let equals: (@MainActor (Value, Value) -> Bool)?

  /// Declares a source whose states all start at the same value.
  init(
    startingValue: Value,
    equals: (@MainActor (Value, Value) -> Bool)?,
    lifetime: CogStateLifetime = .app,
    label: CogLabel
  ) {
    self.label = label
    self.lifetime = lifetime
    self.start = .constant(startingValue)
    self.equals = equals
  }

  /// Declares a keyed source whose states start at a value computed from the
  /// key.
  ///
  /// ``ManualCogBox`` wraps the typed closure before storing it here, so key
  /// erasure never reaches user code.
  init(
    startingValueForKey: @escaping @MainActor (AnyHashable?) -> Value,
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
  /// Repeated reads and writes use the resident value and never rerun a per-key
  /// initializer unless a future releasable-manual policy recreates the state.
  ///
  /// - Parameter key: The state's key, or `nil` for a keyless declaration.
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
  /// Without a comparator, every write counts as changed. Public overloads
  /// choose this statically instead of discovering `Equatable` at runtime.
  func valuesAreEqual(_ oldValue: Value, _ newValue: Value) -> Bool {
    equals?(oldValue, newValue) ?? false
  }

  // Written out, and `nonisolated`, per the rule at the top of
  // `CogDescriptor.swift`. Removing it crashes the release build.
  nonisolated deinit {}
}

/// The two forms a manual declaration's starting value can take.
///
/// The constant case avoids a closure allocation and call. Public initializers
/// select the case from `(0)` or `{ key in ... }`. The per-key closure is
/// MainActor-isolated because lazy state creation is graph work; the erased key
/// adapter restores the public key type before user code observes it.
internal enum ManualCogStartingValue<Value> {
  /// Every state of the declaration starts at this value.
  case constant(Value)

  /// Each state starts at what this returns for its own key.
  case perKey(@MainActor (AnyHashable?) -> Value)
}
