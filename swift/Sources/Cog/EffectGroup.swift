/// A terminal ownership handle for reaction tokens and named tasks.
///
/// Add each effect token to the group and keep the group alive for exactly as
/// long as those effects should exist. `EffectGroup` is a final class, so
/// assigning it elsewhere creates another reference to the same terminal
/// cancellation resource rather than a second group.
///
/// Groups are MainActor-isolated. Ownership is explicit rather than tied to a
/// view or scene automatically: add registrations and create tasks through the
/// group, then cancel or release it at the domain lifetime boundary. Cancelling
/// requests cooperative task cancellation and synchronously cancels reaction
/// registrations; it does not wait for task operations to finish.
@MainActor
public final class EffectGroup {
  /// Live reaction handles retained until group cancellation.
  private var reactionTokens: [ReactionToken] = []

  /// Named tasks retained so the group can cancel them as one unit.
  private var tasks: [Task<Void, any Error>] = []

  /// Terminal state shared by every reference to this group.
  private var isCancelled = false

  /// Package-only deterministic signal for actor-isolated ARC cleanup.
  private var deinitCleanupAcknowledgement: (@MainActor @Sendable () -> Void)?

  /// Creates an empty live group with no effects or tasks.
  public init() {}

  /// Performs terminal cancellation before the last group reference disappears.
  ///
  /// Isolation lets token and task ownership be cleared synchronously on the
  /// MainActor. Tests may observe completion through the package hook below.
  isolated deinit {
    cancel()
    deinitCleanupAcknowledgement?()
  }

  /// Installs the package-only signal emitted after isolated deinit cleanup.
  ///
  /// `CogTesting` uses this acknowledgement instead of sleeping or inspecting
  /// private ownership arrays.
  ///
  /// - Parameter body: The MainActor callback invoked after `cancel()` returns.
  package func acknowledgeDeinitCleanup(
    with body: @escaping @MainActor @Sendable () -> Void
  ) {
    deinitCleanupAcknowledgement = body
  }

  /// Gives this group ownership of one reaction registration.
  ///
  /// The group retains `token` until terminal cancellation. If cancellation
  /// already happened, the token is cancelled immediately and never retained,
  /// so adding to a stopped group cannot revive effects.
  ///
  /// - Parameter token: A live reaction or watch handle to own.
  public func add(_ token: ReactionToken) {
    guard !isCancelled else {
      token.cancel()
      return
    }
    reactionTokens.append(token)
  }

  /// Starts a named task and gives this group ownership of its lifetime.
  ///
  /// A task requested after cancellation is cancelled before this method
  /// returns and is not retained. Otherwise the group keeps the task even after
  /// normal completion, until the group reaches its terminal boundary.
  ///
  /// The task begins on the MainActor and first checks cancellation. The
  /// operation then runs with the isolation expressed at its declaration;
  /// cancellation remains cooperative. Errors are stored in the returned task
  /// and are not converted into Cog state or debug-history events.
  ///
  /// - Parameters:
  ///   - name: The task-local name exposed to Apple task diagnostics.
  ///   - operation: The throwing async work to start and own.
  /// - Returns: The exact task owned by the group, allowing callers to await
  ///   its result when needed.
  @discardableResult
  public func task(
    name: String,
    _ operation: sending @escaping @isolated(any) () async throws -> Void
  ) -> Task<Void, any Error> {
    let task = Task(name: name) { @MainActor in
      try Task.checkCancellation()
      try await operation()
    }
    guard !isCancelled else {
      task.cancel()
      return task
    }
    tasks.append(task)
    return task
  }

  /// Cancels every owned effect and leaves this group terminal.
  ///
  /// Repeated calls do nothing. Every reference to this final-class handle
  /// observes the same cancellation. Reaction cancellation removes graph edges
  /// and leases synchronously; task cancellation is a request and this method
  /// does not await cooperative shutdown. Stored handles are released before
  /// cancellation callbacks run, avoiding reentrant ownership surprises.
  public func cancel() {
    guard !isCancelled else { return }
    isCancelled = true

    let tokens = reactionTokens
    reactionTokens.removeAll()
    let ownedTasks = tasks
    tasks.removeAll()
    for token in tokens {
      token.cancel()
    }
    for task in ownedTasks {
      task.cancel()
    }
  }
}
