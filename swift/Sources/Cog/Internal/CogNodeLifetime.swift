/// How long a declaration asks its context to retain each of its nodes.
///
/// The policy belongs to the descriptor so every copied ref and every key of a
/// box agrees. This is deliberately not the complete public lifetime surface:
/// M1's later release slice adds grace scheduling, and manual opt-in also has
/// to say whether recreation resets to the starting value.
internal nonisolated enum CogNodeLifetime: Equatable {
  /// Retain the node until its app or isolated testing context ends.
  case app

  /// Retain the node while an external consumer leases it, plus a grace period.
  case whileObserved

  /// The lifetime selected by synchronous-derived `keepAlive` sugar.
  init(keepAlive: Bool) {
    self = keepAlive ? .app : .whileObserved
  }
}
