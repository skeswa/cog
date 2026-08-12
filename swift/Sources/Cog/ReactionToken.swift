/// A handle for one reaction registration.
///
/// The context owns the live registration. Holding this final-class token
/// keeps one stable identity for the cancellation and lifecycle operations
/// added by the reaction-token slice.
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
  /// Spelled `isolated`, which is the opposite of what the states and
  /// descriptors need. A `deinit` is nonisolated unless it says otherwise, and
  /// a nonisolated one here could not call into the graph at all; those types
  /// are generic classes, where an isolated `deinit` instead crashes the
  /// release optimizer. This class is not generic, so it can have the
  /// isolation, and the isolation is what lets a token released on the
  /// MainActor cancel synchronously — before the next line of the code that
  /// dropped it, with nothing to await. A token released anywhere else hops,
  /// which is why stopping an effect *now* remains ``cancel()``'s job.
  isolated deinit {
    reaction.cancel()
    deinitCleanupAcknowledgement?()
  }
}
