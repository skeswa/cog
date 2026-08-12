/// An ownership handle for reactions and, later, named effect tasks.
///
/// Add each effect token to the group and keep the group alive for exactly as
/// long as those effects should exist. `EffectGroup` is a final class, so
/// assigning it elsewhere creates another reference to the same terminal
/// cancellation resource rather than a second group.
@MainActor
public final class EffectGroup {
  private var reactionTokens: [ReactionToken] = []
  private var tasks: [Task<Void, any Error>] = []
  private var isCancelled = false

  /// Creates an empty live group.
  public init() {}

  isolated deinit {
    cancel()
  }

  /// Gives this group ownership of one reaction registration.
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
  /// returns and is not retained.
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
  /// observes the same cancellation.
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
