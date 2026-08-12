/// How long a declaration asks its context to retain each of its states.
///
/// The policy belongs to the descriptor so every copied value reference and every key of a
/// box agrees. This is deliberately not the complete public lifetime surface:
/// Manual opt-in also has to say whether recreation resets to the starting
/// value, which remains a later slice.
internal nonisolated enum CogStateLifetime: Equatable {
  /// Retain the state until its app or isolated testing context ends.
  case app

  /// Retain the state while an external consumer leases it, plus a grace period.
  ///
  /// `nil` resolves through the owning context's default. Keeping the optional
  /// on the descriptor lets a later public per-declaration policy supply an
  /// explicit duration without changing the release engine.
  case whileObserved(grace: Duration?)

  /// The lifetime selected by synchronous-derived `keepAlive` sugar.
  init(keepAlive: Bool) {
    self = keepAlive ? .app : .whileObserved(grace: nil)
  }
}
