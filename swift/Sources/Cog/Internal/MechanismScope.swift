/// The terminal ownership boundary behind one mechanism or `whenever` scope.
///
/// A scope owns reactions, tasks, child scopes, and their
/// ``MechanismController``. The runtime keeps one scope per mechanism. Each open
/// `whenever` gate adds a child to its parent, so parent cancellation closes the
/// whole tree.
///
/// Cancellation is final and safe to repeat. New registrations are cancelled at
/// once, and a closed scope cannot reopen. Task cancellation stays cooperative.
/// The controller is released after its work is cancelled, so weak captures
/// become inert when the scope ends.
///
/// Scopes are MainActor-isolated final classes. None of this surface is
/// public API: application code expresses lifetime through assembly and
/// `whenever` gates, never through a handle (§6.2–§6.3).
@MainActor
internal final class MechanismScope {
  /// Live reaction handles retained until scope cancellation.
  private var reactionTokens: [ReactionToken] = []

  /// Named tasks retained so the scope can cancel them as one unit.
  private var tasks: [Task<Void, any Error>] = []

  /// Open child scopes, each owned by a `whenever` gate inside this scope.
  ///
  /// A gate that closes normally disowns its child first; parent cancellation
  /// sweeps whatever is still open so a nested scope can never outlive its
  /// ancestor.
  private var childScopes: [MechanismScope] = []

  /// The controller whose registrations this scope owns.
  ///
  /// Retained until cancellation so async and delegate work can hold a weak
  /// reference for the allowed graph lifetime.
  private var controller: MechanismController?

  /// Terminal state shared by every reference to this scope.
  private var isCancelled = false

  /// Creates an empty live scope with no registrations.
  internal init() {}

  /// Performs terminal cancellation before the last scope reference disappears.
  ///
  /// Isolation lets ownership be cleared synchronously on the MainActor. The
  /// runtime cancels scopes explicitly during its own teardown; this deinit
  /// covers a scope released early, such as a closed `whenever` child.
  isolated deinit {
    cancel()
  }

  /// Gives this scope ownership of the controller that registers through it.
  ///
  /// The runtime and `whenever` call this exactly once, immediately after
  /// creating the controller and before `operate` or a scope body runs.
  internal func retain(controller: MechanismController) {
    guard !isCancelled else { return }
    self.controller = controller
  }

  /// Gives this scope ownership of one reaction registration.
  ///
  /// If cancellation already happened, the token is cancelled immediately and
  /// never retained, so a registration racing a teardown cannot revive the
  /// scope.
  internal func add(_ token: ReactionToken) {
    guard !isCancelled else {
      token.cancel()
      return
    }
    reactionTokens.append(token)
  }

  /// Registers an open `whenever` child for parent-cascade cancellation.
  internal func adopt(child: MechanismScope) {
    guard !isCancelled else {
      child.cancel()
      return
    }
    childScopes.append(child)
  }

  /// Forgets a child whose gate closed normally.
  ///
  /// The gate cancels the child itself; removal only keeps a long-lived
  /// parent from accumulating dead children across gate cycles.
  internal func disown(child: MechanismScope) {
    childScopes.removeAll { $0 === child }
  }

  /// Starts a named task and gives this scope ownership of its lifetime.
  ///
  /// A task requested after cancellation is cancelled before this method
  /// returns and is not retained. Otherwise the scope keeps the task even
  /// after normal completion, until the scope reaches its terminal boundary.
  ///
  /// The task begins on the MainActor and first checks cancellation. The
  /// operation then runs with the isolation expressed at its declaration;
  /// cancellation remains cooperative. Errors are stored in the returned task
  /// and are not converted into Cog state or debug-history events.
  ///
  /// - Parameters:
  ///   - name: The task-local name exposed to Apple task diagnostics.
  ///   - operation: The throwing async work to start and own.
  /// - Returns: The exact task owned by the scope.
  @discardableResult
  internal func task(
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

  /// Cancels everything this scope owns and leaves it terminal.
  ///
  /// Children cancel first so they never see a half-closed parent. Reactions
  /// and tasks follow, then the controller. Stored handles are removed before
  /// their cancellation callbacks run, which avoids reentrant ownership changes.
  internal func cancel() {
    guard !isCancelled else { return }
    isCancelled = true

    let children = childScopes
    childScopes.removeAll()
    let tokens = reactionTokens
    reactionTokens.removeAll()
    let ownedTasks = tasks
    tasks.removeAll()

    for child in children {
      child.cancel()
    }
    for token in tokens {
      token.cancel()
    }
    for task in ownedTasks {
      task.cancel()
    }
    controller = nil
  }
}
