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
  /// Cancellation blocks later turns and runs already queued by the current
  /// flush.
  ///
  /// Repeated calls do nothing.
  ///
  /// Token copies share one registration. Cancelling any copy stops it.
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
  /// The isolated deinitializer can cancel synchronously when the token is
  /// released on the MainActor. A release elsewhere may hop to the MainActor,
  /// so call ``cancel()`` when the reaction must stop immediately.
  isolated deinit {
    reaction.cancel()
    deinitCleanupAcknowledgement?()
  }
}
