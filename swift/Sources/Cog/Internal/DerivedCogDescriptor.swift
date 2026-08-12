/// The descriptor behind a derived cog declaration.
///
/// ``Cog`` and ``CogBox`` share this descriptor type. It is generic over the
/// value; the reference carries an erased key (perf §4).
///
/// Every state for the declaration uses the selector stored here.
internal final class DerivedCogDescriptor<Value>: CogDescriptor {
  let label: CogLabel

  /// Whether states of this declaration are releasable when unobserved.
  ///
  /// Synchronous derived values default to `whileObserved` because Cog can
  /// recompute them. The public `keepAlive` declaration sugar instead stores
  /// `app`; the lifetime engine uses this policy when it schedules release.
  let lifetime: CogStateLifetime

  /// How a state of this declaration computes its value.
  ///
  /// Explicit `@MainActor` keeps the closure isolated under any caller default
  /// (§1.2, §2.5, §7). Synchronous selectors cannot throw in v1, which makes a
  /// throwing declaration fail to compile (`DECL-12`).
  private let selector: @MainActor (Reader<Value>, AnyHashable?) -> Value

  /// Whether two computed values count as the same state, or `nil` when every
  /// recomputation must conservatively count as a change.
  private let equals: (@MainActor (Value, Value) -> Bool)?

  /// Declares a derived value computed by `selector`.
  init(
    selector: @escaping @MainActor (Reader<Value>, AnyHashable?) -> Value,
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
  /// Keyless and keyed declarations share this call site.
  func compute(_ reader: Reader<Value>, key: AnyHashable?) -> Value {
    selector(reader, key)
  }

  /// Whether a recomputation is equivalent to the state's cached value.
  ///
  /// The public declaration overloads install `==`, preserve a custom rule,
  /// or leave the comparator absent so an opaque value assumes change.
  func valuesAreEqual(_ oldValue: Value, _ newValue: Value) -> Bool {
    equals?(oldValue, newValue) ?? false
  }

  // Written out, and `nonisolated`, per the rule at the top of
  // `CogDescriptor.swift`. Removing it crashes the release build.
  nonisolated deinit {}
}
