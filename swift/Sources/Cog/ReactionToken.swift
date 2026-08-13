/// The lifetime handle for one reaction or watch registration.
///
/// Keep the token alive for as long as the reaction should run. Releasing the
/// last reference cancels the registration. Call ``cancel()`` when it must stop
/// at a specific point.
///
/// ```swift
/// let token = cogs.run { c in
///   updateBadge(c[unreadCount])
/// }
/// defer { token.cancel() }
/// ```
///
/// A token is a MainActor-isolated reference type. Additional references share
/// one registration rather than copying it. The owning ``Cogtext`` keeps the
/// registration in execution order, while the last token reference controls
/// when its body, dependency edges, and `whileObserved` leases are removed.
@MainActor
public final class ReactionToken {
  /// The exact context-owned registration controlled by every token reference.
  ///
  /// The context also retains the registration to preserve execution order,
  /// but token lifetime determines whether it remains active: deinitialization
  /// cancels the registration before releasing this reference.
  internal let reaction: CogReaction

  /// One package-only deinit signal consumed by deterministic cleanup tests.
  private var deinitCleanupAcknowledgement: (@MainActor @Sendable () -> Void)?

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
  public func cancel() {
    reaction.cancel()
  }

  /// Installs the package-only signal emitted after isolated deinit cleanup.
  ///
  /// `CogTesting` uses this to await actor-correct ARC cleanup without polling
  /// graph storage. Production clients cannot install the hook.
  ///
  /// - Parameter body: The MainActor acknowledgement invoked after cancellation.
  package func acknowledgeDeinitCleanup(
    with body: @escaping @MainActor @Sendable () -> Void
  ) {
    deinitCleanupAcknowledgement = body
  }

  /// Cancels the registration once the last handle to it goes away.
  ///
  /// The isolated deinitializer can cancel synchronously when the token is
  /// released on the MainActor. A release elsewhere may hop to the MainActor,
  /// so call ``cancel()`` when ordering requires the registration to be gone
  /// before the next statement.
  isolated deinit {
    reaction.cancel()
    deinitCleanupAcknowledgement?()
  }
}
