/// Whether the arena's size-for-speed specialization was compiled.
internal nonisolated enum CogArenaSpecialization {
  /// Specialization is the default; the public `CompactArena` trait suppresses it.
  static var compiled: Bool {
    #if COG_ARENA_COMPACT
    false
    #else
    true
    #endif
  }
}
