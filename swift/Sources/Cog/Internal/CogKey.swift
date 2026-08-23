/// The key half of a value reference's identity.
///
/// A keyed declaration — ``CogBox.Manual``, ``CogBox``, or ``CogBox.Async`` —
/// names a family of states, and `box[key]` builds a lightweight reference to
/// one of them. Perf §4 and §9.6 selected inline `AnyHashable` after comparing
/// it with interned-token and generic-keyed candidates. Those experiments are
/// preserved in the benchmark record rather than in the shipping source.
///
/// Value references, state identities, descriptors, and diagnostics carry an
/// optional `CogKey` and reach the original key through ``erased``.
/// `nonisolated` because `Hashable` requires nonisolated equality, matching
/// ``CogStateIdentity``, which is built on the MainActor and compared anywhere.
#if !COG_ARENA_COMPACT
@usableFromInline
#endif
internal nonisolated struct CogKey: Hashable {
  /// The original key, type-erased inline in the value reference.
  let erased: AnyHashable

  /// Carries one key into a value reference.
  ///
  /// - Parameter key: The value `box[key]` was given.
  init(_ key: some Hashable) {
    erased = AnyHashable(key)
  }

  /// Carries an already-erased key without nesting another existential.
  ///
  /// `AnyHashable` is itself `Hashable`; a distinct initializer prevents equal
  /// singly and doubly erased keys from naming different states.
  init(erased key: AnyHashable) {
    erased = key
  }
}
