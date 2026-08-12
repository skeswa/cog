/// An ownership handle for reactions and, later, named effect tasks.
///
/// Add each effect token to the group and keep the group alive for exactly as
/// long as those effects should exist. `EffectGroup` is a final class, so
/// assigning it elsewhere creates another reference to the same terminal
/// cancellation resource rather than a second group.
@MainActor
public final class EffectGroup {
  private var reactionTokens: [ReactionToken] = []
  private var isCancelled = false

  /// Creates an empty live group.
  public init() {}

  isolated deinit {
    cancel()
  }

  /// Gives this group ownership of one reaction registration.
  ///
  /// The terminal add-after-cancel rule is completed by M1-23da. Until then,
  /// callers add effects only to a live group.
  public func add(_ token: ReactionToken) {
    reactionTokens.append(token)
  }

  /// Cancels every owned effect and leaves this group terminal.
  ///
  /// Repeated calls do nothing. Every reference to this final-class handle
  /// observes the same cancellation.
  public func cancel() {
    guard !isCancelled else { return }
    isCancelled = true

    let tokens = reactionTokens
    reactionTokens.removeAll()
    for token in tokens {
      token.cancel()
    }
  }
}
