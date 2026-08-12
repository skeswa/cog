/// A handle for one reaction registration.
///
/// The context owns the live registration. Holding this final-class token
/// keeps one stable identity for the cancellation and lifecycle operations
/// added by the reaction-token slice.
@MainActor
public final class ReactionToken {
  internal let reaction: CogReaction

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
}
