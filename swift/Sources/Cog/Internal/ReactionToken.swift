/// The internal lifetime handle for one reaction or watch registration.
///
/// Registration handles are not public API: a registration lives until its
/// owning ``MechanismScope`` ends, and shorter lifetimes are `whenever` gates
/// expressed in state (§6.2). The scope keeps the token alive; releasing the
/// last reference cancels the registration, and ``cancel()`` stops it at a
/// specific point during scope teardown.
///
/// A token is a MainActor-isolated reference type. Additional references share
/// one registration rather than copying it. The owning ``Cogs`` keeps the
/// registration in execution order, while the last token reference controls
/// when its body, dependency edges, and `whileObserved` leases are removed.
///
/// This class stays non-generic so its `isolated deinit` can cancel
/// synchronously when released on the MainActor.
@MainActor
internal final class ReactionToken {
  /// The exact context-owned registration controlled by every token reference.
  ///
  /// The context also retains the registration to keep execution order. The
  /// token decides whether it stays active; deinitialization cancels it before
  /// releasing this reference.
  internal let reaction: CogReaction

  /// Wraps a newly registered reaction without creating another registration.
  ///
  /// - Parameter reaction: The context-owned registration whose dependency
  ///   edges, leases, and future runs this token controls.
  internal init(reaction: CogReaction) {
    self.reaction = reaction
  }

  /// Stops this registration for good.
  ///
  /// Cancellation blocks later turns and runs already queued by the current
  /// flush, removes dependency edges, and releases every reaction-owned
  /// lifetime lease synchronously on the MainActor. It does not undo effect
  /// code that already ran or cancel unrelated work started by that code.
  ///
  /// Repeated calls do nothing.
  ///
  /// Every reference to this token shares one terminal registration;
  /// cancelling through any reference stops it for all of them.
  internal func cancel() {
    reaction.cancel()
  }

  /// Cancels the registration once the last handle to it goes away.
  ///
  /// The isolated deinitializer can cancel synchronously when the token is
  /// released on the MainActor. A release elsewhere may hop to the MainActor,
  /// so call ``cancel()`` when ordering requires the registration to be gone
  /// before the next statement.
  isolated deinit {
    reaction.cancel()
  }
}
