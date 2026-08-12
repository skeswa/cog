/// The descriptor behind a derived cog declaration.
///
/// One descriptor stands behind one ``Cog`` declaration or one ``CogBox``,
/// for the same reason ``ManualCogDescriptor`` stands behind both manual
/// forms: the correctness build spells keys as an inline
/// `AnyHashable?` on the value reference (perf §4), so the declaration is generic over its
/// value and knows nothing about a key type.
///
/// What a derived declaration owns that a manual one does not is the selector.
/// It lives here rather than on the state because it belongs to the
/// declaration: every state of this declaration, in every context, computes
/// with the same closure, and a context that has never been asked for the
/// declaration holds nothing at all.
internal final class DerivedCogDescriptor<Value>: CogDescriptor {
  let label: CogLabel

  /// Whether states of this declaration are releasable when unobserved.
  ///
  /// Synchronous derived values default to `whileObserved` because Cog can
  /// recompute them. The public `keepAlive` declaration sugar instead stores
  /// `app`; the later lifetime engine consumes this policy when it schedules
  /// release.
  let lifetime: CogStateLifetime

  /// How a state of this declaration computes its value.
  ///
  /// `@MainActor` because the graph is (§1.2, §2.5), stated explicitly so the
  /// closure type says the same thing whatever a caller's default isolation is
  /// (§7). Not `throws`: synchronous selectors do not throw in v1 (§2.4), and
  /// leaving the throw out of the type is what makes that a compile error at
  /// the declaration site rather than a runtime rule (`DECL-12`).
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
  /// A method rather than an exposed closure so the state has one seam to call
  /// however the declaration was spelled. A keyed form passes its key through
  /// here, and nothing at the call site has to know which form ran.
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
