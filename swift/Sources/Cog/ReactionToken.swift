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
}
