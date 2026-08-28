/// How long a source declaration asks a context to keep each of its states.
///
/// Sources default to ``app`` because their values exist nowhere else. A
/// released source can return only at its starting value. A draft, filter, or
/// per-screen selection can opt into that reset with
/// ``whileObserved(resetToInitial:grace:)`` (§5.3).
///
/// The policy is declaration metadata shared by every key of a
/// ``CogBox/Manual`` and by every context. Each keyed state still owns its own
/// leases and grace deadline.
public enum ManualCogLifetime: Sendable {
  /// Keep every state of this declaration until its context ends.
  ///
  /// The default. Nothing but context teardown removes the value, so a source
  /// nobody has watched for hours still answers with what was last written to
  /// it.
  case app

  /// Release a state once nothing observes it, and start the next one over.
  ///
  /// A reaction leases the source, and a UI read pins it. Other reads and
  /// writes are not durable observers. Once no lease or pin remains, the state
  /// gets one grace window. A later read recreates an expired state at the
  /// declaration's starting value.
  ///
  /// - Parameters:
  ///   - resetToInitial: Must be `true`. The parameter exists so the call site
  ///     states the consequence, not to offer a second behavior: a released
  ///     source has no retained value to come back as. Declare ``app`` to keep
  ///     a source's value instead.
  ///   - grace: How long an unobserved state waits before release. `nil` uses
  ///     the context default: 30 seconds in production or the value injected
  ///     by a test.
  case whileObserved(resetToInitial: Bool, grace: Duration? = nil)

  /// The internal policy this declaration stores, rejecting the one spelling
  /// Cog cannot honor.
  ///
  /// `resetToInitial: false` asks for a source that is released without losing
  /// its value, which no released state can do. Trapping here reports it at the
  /// declaration that made the promise, in every build, rather than letting a
  /// value quietly disappear at the first grace expiry.
  internal var stateLifetime: CogStateLifetime {
    switch self {
    case .app:
      return .app
    case .whileObserved(let resetToInitial, let grace):
      guard resetToInitial else {
        fatalError(
          """
          A Cog source cannot be released without resetting to its starting \
          value: a released source keeps nothing to come back as. Declare \
          .app to keep this source's value for the life of the context, or \
          .whileObserved(resetToInitial: true) to let it go and start over.
          """
        )
      }
      return .whileObserved(grace: grace)
    }
  }
}
