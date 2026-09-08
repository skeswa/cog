/// The terminal ownership boundary behind one mechanism or `scope` child.
///
/// A scope owns reactions, tasks, child scopes, and their
/// ``MechanismController``. The runtime keeps one scope per mechanism. Each open
/// `scope` child adds itself to its parent, so parent retirement closes the
/// whole tree.
///
/// Retirement is final and safe to repeat. New registrations are cancelled at
/// once, and a closed scope cannot reopen. Task cancellation stays cooperative.
/// The controller is released after its work is cancelled, so weak captures
/// become inert when the scope ends.
///
/// Retirement happens in two steps, and the order is the contract. ``revoke()``
/// marks this scope and every descendant retired *before* any teardown work
/// runs; ``cancel()`` then performs the teardown. Splitting them is what makes
/// the guarantee independent of traversal order: a cancellation callback that
/// runs while an ancestor is tearing down cannot find a not-yet-visited sibling
/// or descendant still willing to register work or open a turn. A controller
/// asks ``isRetired`` before it touches the graph, so one flag answers for the
/// whole subtree.
///
/// Scopes are MainActor-isolated final classes. None of this surface is
/// public API: application code expresses lifetime through assembly and
/// `scope` registrations, never through a handle (§6.2–§6.3).
@MainActor
internal final class MechanismScope {
  /// Live reaction handles retained until scope retirement.
  private var reactionTokens: [ReactionToken] = []

  /// Named tasks retained so the scope can cancel them as one unit.
  private var tasks: [Task<Void, any Error>] = []

  /// Open child scopes, each owned by a `scope` registration inside this scope.
  ///
  /// A registration that retires a child normally disowns it first; parent
  /// retirement sweeps whatever is still open so a nested scope can never
  /// outlive its ancestor.
  private var childScopes: [MechanismScope] = []

  /// The controller whose registrations this scope owns.
  ///
  /// Retained until retirement so async and delegate work can hold a weak
  /// reference for the allowed graph lifetime.
  private var controller: MechanismController?

  /// Whether this scope has lost its authority to act on the graph.
  ///
  /// Set by ``revoke()`` across the whole subtree before any teardown begins,
  /// so it is true for every descendant from the first moment an ancestor
  /// starts retiring. Every controller primitive reads it.
  private(set) var isRetired = false

  /// Whether this scope has already released everything it owns.
  ///
  /// Separate from ``isRetired`` because revocation runs first and teardown
  /// must still happen exactly once afterward.
  private var hasTornDown = false

  /// Creates an empty live scope with no registrations.
  internal init() {}

  /// Performs terminal retirement before the last scope reference disappears.
  ///
  /// Isolation lets ownership be cleared synchronously on the MainActor. The
  /// runtime retires scopes explicitly during its own teardown; this deinit
  /// covers a scope released early, such as a child whose selector closed it.
  isolated deinit {
    cancel()
  }

  /// Marks this scope and every descendant retired without releasing anything.
  ///
  /// Revocation is the authority half of retirement and always precedes the
  /// ownership half. It is a pure marking pass: it runs no cancellation
  /// callback, releases no closure, and therefore cannot reenter this scope
  /// tree while it is still partly live. By the time ``cancel()`` starts
  /// cancelling reactions and tasks, every controller in the subtree already
  /// answers "retired", so a cancellation callback that reaches for a sibling
  /// or a descendant finds it inert rather than merely unvisited.
  internal func revoke() {
    guard !isRetired else { return }
    isRetired = true
    for child in childScopes {
      child.revoke()
    }
  }

  /// Gives this scope ownership of the controller that registers through it.
  ///
  /// The runtime and every `scope` opening call this exactly once, immediately
  /// after creating the controller and before `operate` or a registration body
  /// runs.
  internal func retain(controller: MechanismController) {
    guard !isRetired else { return }
    self.controller = controller
  }

  /// Gives this scope ownership of one reaction registration.
  ///
  /// If retirement already happened, the token is cancelled immediately and
  /// never retained, so a registration racing a teardown cannot revive the
  /// scope. The public controller path checks ``isRetired`` before it builds a
  /// registration at all; this check remains the terminal ownership defense
  /// for a body that retires its own scope while it is still initializing.
  internal func add(_ token: ReactionToken) {
    guard !isRetired else {
      token.cancel()
      return
    }
    reactionTokens.append(token)
  }

  /// Registers an open `scope` child for parent-cascade retirement.
  internal func adopt(child: MechanismScope) {
    guard !isRetired else {
      child.cancel()
      return
    }
    childScopes.append(child)
  }

  /// Forgets a child that its selector retired normally.
  ///
  /// The selector cancels the child itself; removal only keeps a long-lived
  /// parent from accumulating dead children across replacements.
  internal func disown(child: MechanismScope) {
    childScopes.removeAll { $0 === child }
  }

  /// Starts a named task and gives this scope ownership of its lifetime.
  ///
  /// A task requested after retirement is cancelled before this method
  /// returns and is not retained; its operation never starts, because the task
  /// body checks cancellation before awaiting it. Otherwise the scope keeps the
  /// task even after normal completion, until the scope reaches its terminal
  /// boundary.
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
    guard !isRetired else {
      task.cancel()
      return task
    }
    tasks.append(task)
    return task
  }

  /// Retires this scope and releases everything it owns.
  ///
  /// Revocation marks the whole subtree first, so nothing in it can start new
  /// graph work once this call begins. Children are then torn down before
  /// their parent's own registrations, so they never see a half-closed parent.
  /// Reactions and tasks follow, then the controller. Stored handles are
  /// removed before their cancellation callbacks run, which avoids reentrant
  /// ownership changes.
  internal func cancel() {
    revoke()
    guard !hasTornDown else { return }
    hasTornDown = true

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
