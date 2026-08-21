/// What a ``Cogs`` files a state under: a declaration plus a key.
///
/// Identity is the descriptor's `ObjectIdentifier` plus an optional key (§2.3,
/// §3.1).
/// Context ownership supplies the namespace: equal identities in different
/// contexts deliberately address independent states.
///
/// The type is `nonisolated` because `Hashable` requires nonisolated equality.
/// It is still built on the MainActor.
///
/// The key's physical layout is `CogKey`'s to choose, selected at build time
/// and open until benchmarks settle it (perf §4, §9).
#if !COG_ARENA_COMPACT
@usableFromInline
#endif
internal nonisolated struct CogStateIdentity: Hashable {
  /// The declaration, by process identity.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  let descriptor: ObjectIdentifier

  /// Which state of `descriptor` this names, or `nil` for a keyless
  /// declaration.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  let key: CogKey?

  /// Forms the context-local lookup key for one public value reference.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  init(descriptor: ObjectIdentifier, key: CogKey?) {
    self.descriptor = descriptor
    self.key = key
  }
}
