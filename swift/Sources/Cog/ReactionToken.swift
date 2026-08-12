/// A handle for one reaction registration.
///
/// Keep the token alive for as long as the reaction should run. Releasing the
/// last reference cancels the registration. Call ``cancel()`` when it must stop
/// at a specific point.
///
/// ```swift
/// let token = cogs.run { c in
///   updateBadge(c.get(unreadCount))
/// }
/// defer { token.cancel() }
/// ```
@MainActor
public final class ReactionToken {
  internal let reaction: CogReaction
  private var deinitCleanupAcknowledgement: (@MainActor @Sendable () -> Void)?

  internal init(reaction: CogReaction) {
    self.reaction = reaction
  }

  /// Stops this registration for good.
  ///
  /// The reaction does not run again: not on a later turn, and not from a run
  /// the flush in progress had already queued for it. This is the fixed
  /// stopping point a lifecycle owner or a test can name, rather than whenever
  /// the last handle happens to die.
  ///
  /// Safe to call as often as you like. The first call cancels and every later
  /// one returns without doing anything, so two cleanup paths that overlap do
  /// not have to coordinate.
  ///
  /// Cancellation belongs to the registration rather than to this handle.
  /// Copying a token copies a reference to the same registration, so
  /// cancelling through any copy stops the one reaction all of them name.
  public func cancel() {
    reaction.cancel()
  }

  /// Installs the test-only signal emitted after isolated deinit cleanup.
  package func acknowledgeDeinitCleanup(
    with body: @escaping @MainActor @Sendable () -> Void
  ) {
    deinitCleanupAcknowledgement = body
  }

  /// Cancels the registration once the last handle to it goes away.
  ///
  /// An effect that nobody can still reach is an effect nobody can still stop,
  /// so letting the registration run on would leak work no caller could
  /// account for. Dropping the last token is therefore a way of ending an
  /// effect, not a way of leaking one.
  ///
  /// The isolated deinitializer can cancel synchronously when the token is
  /// released on the MainActor. A release elsewhere may hop to the MainActor,
  /// so call ``cancel()`` when the reaction must stop immediately.
  isolated deinit {
    reaction.cancel()
    deinitCleanupAcknowledgement?()
  }
}
