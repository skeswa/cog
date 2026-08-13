/// How long a declaration asks its context to retain each of its states.
///
/// The descriptor shares this policy across copied references and box keys.
/// A later manual-state API will also choose whether recreation resets to the
/// starting value. The policy is immutable declaration metadata; each keyed
/// state owns its own lease count, grace generation, and deadline task.
internal nonisolated enum CogStateLifetime: Equatable {
  /// Retain the state until its app or isolated testing context ends.
  case app

  /// Retain the state while an external consumer leases it, plus a grace period.
  ///
  /// `nil` resolves through the owning context's default. Keeping the optional
  /// on the descriptor lets a later public per-declaration policy supply an
  /// explicit duration without changing the release engine. A reaction lease
  /// or first UI boundary is durable observation; a graph-internal subscriber
  /// delays removal but neither renews nor restarts grace.
  case whileObserved(grace: Duration?)

  /// The lifetime selected by synchronous-derived `keepAlive` sugar.
  init(keepAlive: Bool) {
    self = keepAlive ? .app : .whileObserved(grace: nil)
  }
}
