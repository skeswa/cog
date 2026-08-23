/// The terminal ownership boundary behind one mechanism or `whenever` scope.
///
/// A scope owns reaction registrations, named tasks, child scopes, and the
/// ``MechanismController`` that registered them. The runtime retains one scope
/// per assembly mechanism, and each open `whenever` gate owns one child scope
/// registered with its parent, so cancelling a parent tears its whole family
/// down as one unit.
///
/// Cancellation is terminal and idempotent: repeated calls do nothing, a
/// registration arriving afterward is cancelled synchronously without being
/// retained, and nothing reopens a cancelled scope. Task cancellation is a
/// cooperative request; the controller is released only after registrations
/// and tasks have been cancelled, which is what lets weakly captured
/// controllers become inert instead of outliving their lifetime.
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
  /// Retained until terminal cancellation so asynchronous and delegate-driven
  /// work may capture the controller weakly for exactly as long as the scope
  /// authorizes graph access.
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
  /// Children cancel first so a nested family never observes a half-closed
  /// ancestor, then reactions and tasks, and only then is the controller
  /// released — the ordering that keeps a mechanism's resources alive until
  /// its last registration is gone. Stored handles are released before their
  /// cancellation callbacks run, avoiding reentrant ownership surprises.
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
