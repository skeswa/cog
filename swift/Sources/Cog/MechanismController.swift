/// The graph capability passed to a mechanism's `operate` method.
///
/// It can register `run`, `watch`, `task`, and gated `whenever` scopes. It also
/// has untracked `peek` reads and the shared ``CogOps`` surface. It cannot expose
/// the raw ``Cogs``. Keeping all access on this controller preserves attribution
/// and lets tests isolate a mechanism (§6.2).
///
/// Its scope retains it, but it does not own the app runtime. Async and delegate
/// work should capture it weakly. When the scope ends, the runtime cancels its
/// work and releases the controller. A `[weak m]` callback then returns when
/// promotion fails. An external engine must not retain the controller past the
/// scope that allowed graph access.
///
/// Every registration is attributed: `watch`, `run`, and `task` names compose
/// under the mechanism's name, and a turn an op opens through the controller
/// records which mechanism asked for it.
@MainActor
public final class MechanismController {
  /// The runtime this controller registers with, or `nil` once it is gone.
  ///
  /// Weak because the runtime owns the controller through its scope; a strong
  /// reference would keep an isolated test context alive through its own
  /// registrations. After the runtime deinitializes, registration and turn
  /// calls become inert.
  private weak var cogtext: Cogs?

  /// The composed attribution name: the mechanism's name, extended by each
  /// named `whenever` scope this controller sits inside.
  internal let namePath: String

  /// The scope that owns every registration this controller makes.
  private let scope: MechanismScope

  /// Creates the capability for one mechanism or `whenever` scope.
  ///
  /// Only assembly and an opening gate construct controllers; the scope
  /// retains the result for exactly the lifetime it authorizes.
  internal init(cogs: Cogs, namePath: String, scope: MechanismScope) {
    self.cogtext = cogs
    self.namePath = namePath
    self.scope = scope
  }

  /// Extends this controller's attribution path with one registration name.
  private func composed(_ name: String?) -> String? {
    name.map { "\(namePath).\($0)" }
  }

  /// Registers `make`'s token with the graph and hands it to this scope.
  ///
  /// After the runtime is gone there is no graph to register with, so the
  /// call is inert. A registration arriving at an already-cancelled scope is
  /// cancelled synchronously without being retained.
  private func register(_ make: (Cogs) -> ReactionToken) {
    guard let cogtext else { return }
    scope.add(make(cogtext))
  }

  /// The runtime for a value-producing call, which cannot be inert.
  ///
  /// Registrations and turns after runtime teardown simply do nothing, but
  /// a read must return a value. Reaching this trap means work captured the
  /// controller strongly across the runtime's death instead of re-promoting a
  /// weak reference around each unit of graph work.
  private var requiredRuntime: Cogs {
    guard let cogtext else {
      // `fatalError`, not `preconditionFailure`: an optimized build drops
      // `preconditionFailure` messages, and this misuse needs its diagnosis.
      fatalError(
        """
        The \(namePath) mechanism read through its controller after the app \
        runtime was gone. Capture the controller weakly — `[weak m]` — and \
        promote it around each unit of graph work so cancelled work returns \
        instead of reading a released graph.
        """
      )
    }
    return cogtext
  }
}

// MARK: - Reactions

extension MechanismController {
  /// Registers a reaction and schedules its first tracking run.
  ///
  /// `run` is the general synchronous effect primitive. The body runs once to
  /// establish its initial dependency set, then reruns after completed turns
  /// only when a value read through its ``ReactionReader`` changed. Every run
  /// replaces the dependency set, so branches may change what triggers later
  /// work. `peek` reads remain one-shot and do not become dependencies.
  ///
  /// The runtime keeps call order, including mechanism order at assembly. A
  /// turn runs only reactions reached by changed state, after their dependencies
  /// settle. Outside a flush, the first run finishes before this method returns.
  /// A reaction added during a flush joins the end of that flush's queue.
  ///
  /// The registration lives until this controller's scope ends; there is no
  /// public token. A shorter lifetime is a ``whenever(_:name:fileID:line:_:)-(Cog<Bool>,_,_,_,_)`` gate expressed in
  /// state.
  ///
  /// - Parameters:
  ///   - fileID: The registration's file for diagnostics. Leave this at its
  ///     default.
  ///   - line: The registration's line for diagnostics. Leave this at its
  ///     default.
  ///   - body: Synchronous effect code. Read graph state through the supplied
  ///     ``ReactionReader``; call ops on this controller to enqueue writes
  ///     rather than retaining the reader.
  public func run(
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ body: @escaping @MainActor (ReactionReader) -> Void
  ) {
    register { cogs in
      cogs.register(label: CogLabel(name: nil, fileID: fileID, line: line), body: body)
    }
  }

  /// Registers a reaction that watches one source and receives its old and
  /// new values.
  ///
  /// Installation reads the source from the latest completed turn and records
  /// its exact descriptor-and-key state as the dependency. `initial` controls
  /// only delivery of that baseline; subscription always occurs. Later
  /// changed source turns run watches in registration order after mutation
  /// has closed. Manual state has context lifetime, so the end of this
  /// controller's scope removes the reaction but does not release or reset
  /// the source.
  ///
  /// - Parameters:
  ///   - valueReference: The source to watch.
  ///   - initial: Whether installation calls `body` once with the baseline as
  ///     both old and new values.
  ///   - name: What Cog should call this effect in debug history, composed
  ///     under the mechanism's name. Defaults to the file and line of the
  ///     registration.
  ///   - fileID: The registration's file for diagnostics. Leave this at its
  ///     default.
  ///   - line: The registration's line for diagnostics. Leave this at its
  ///     default.
  ///   - body: Synchronous effect code, given the value before this change
  ///     and the value after it. The body runs on the MainActor; turns it
  ///     requests during a flush become later FIFO turns.
  public func watch<Value>(
    _ valueReference: Cog<Value>.Manual,
    initial: CogWatchStart,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ body: @escaping @MainActor (Value, Value) -> Void
  ) {
    register { cogs in
      cogs.watchTracked(
        label: CogLabel(name: composed(name), fileID: fileID, line: line),
        initial: initial,
        read: { c in c[valueReference] },
        body: body
      )
    }
  }

  /// Registers a reaction that watches one automatic cog and receives its old
  /// and new values.
  ///
  /// Installation settles the exact descriptor-and-key state, records it as
  /// the watch's dependency, and captures the returned value as the baseline.
  /// ``CogWatchStart/skip`` suppresses only the initial body call; it does
  /// not skip settlement or subscription. Outside a flush installation
  /// completes synchronously; installation requested during a flush joins
  /// that flush's reaction queue instead of reentering its caller.
  ///
  /// Later changed turns run watches in registration order after dependencies
  /// settle. An equality-gated cog keeps the watch quiet when recomputation
  /// is equal. The registration holds a `whileObserved` lease on the exact
  /// automatic state; the end of this controller's scope cancels both and may
  /// begin grace.
  ///
  /// - Parameters:
  ///   - valueReference: The cog to watch.
  ///   - initial: Whether installation calls `body` once with the baseline as
  ///     both old and new values.
  ///   - name: What Cog should call this effect in debug history, composed
  ///     under the mechanism's name. Defaults to the file and line of the
  ///     registration.
  ///   - fileID: The registration's file for diagnostics. Leave this at its
  ///     default.
  ///   - line: The registration's line for diagnostics. Leave this at its
  ///     default.
  ///   - body: Synchronous effect code, given the value before this change
  ///     and the value after it. The body runs on the MainActor; turns it
  ///     requests during a flush become later FIFO turns.
  public func watch<Value>(
    _ valueReference: Cog<Value>,
    initial: CogWatchStart,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ body: @escaping @MainActor (Value, Value) -> Void
  ) {
    register { cogs in
      cogs.watchTracked(
        label: CogLabel(name: composed(name), fileID: fileID, line: line),
        initial: initial,
        read: { c in c[valueReference] },
        body: body
      )
    }
  }

  /// Registers a reaction that watches an async cog's value.
  ///
  /// Installation settles the internal value projection, records it as the
  /// watch's one tracked dependency, and captures the returned value as the
  /// baseline. A first read can start work, so the baseline is normally the
  /// declaration's resting default. ``CogWatchStart/skip`` suppresses only
  /// the initial body call; it does not skip the read or subscription. If
  /// that cold read establishes pending while the reaction is tracking, Cog
  /// defers the graph-owned pending flush until installation exits rather
  /// than reentering the watch.
  ///
  /// The watch runs when the value changes: a new accepted success, gated by
  /// equality when the declaration is `Equatable`. Reload pending and failure
  /// turns that retain the same value stay quiet; watch through ``status`` to
  /// observe every status turn instead. The registration holds a
  /// `whileObserved` lease reaching the async state through the projection;
  /// the end of this controller's scope cancels the watch and begins ordinary
  /// grace when no other durable consumer remains.
  ///
  /// - Parameters:
  ///   - valueReference: The async value to watch.
  ///   - initial: Whether installation calls `body` with the baseline value
  ///     as both arguments.
  ///   - name: What Cog should call this effect in debug history, composed
  ///     under the mechanism's name. Defaults to the file and line of the
  ///     registration.
  ///   - fileID: The registration's file for diagnostics. Leave this at its
  ///     default.
  ///   - line: The registration's line for diagnostics. Leave this at its
  ///     default.
  ///   - body: Synchronous effect code, given the value before this change
  ///     and the value after it. The body runs on the MainActor; turns it
  ///     requests during a flush become later FIFO turns.
  public func watch<Value>(
    _ valueReference: Cog<Value>.Async,
    initial: CogWatchStart,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ body: @escaping @MainActor (Value, Value) -> Void
  ) {
    register { cogs in
      cogs.watchTracked(
        label: CogLabel(name: composed(name), fileID: fileID, line: line),
        initial: initial,
        read: { c in c[valueReference] },
        body: body
      )
    }
  }

  /// Registers a watch on a source's read-only projection.
  ///
  /// The projection and source name the same state, so installation,
  /// ordering, baseline delivery, and scope teardown match the source
  /// overload. This spelling exposes no write capability to the registration
  /// site.
  ///
  /// - Parameters:
  ///   - valueReference: The read-only value reference to watch.
  ///   - initial: Whether installation calls `body` once with the baseline as
  ///     both old and new values.
  ///   - name: What Cog should call this effect in debug history, composed
  ///     under the mechanism's name. Defaults to the file and line of the
  ///     registration.
  ///   - fileID: The registration's file for diagnostics. Leave this at its
  ///     default.
  ///   - line: The registration's line for diagnostics. Leave this at its
  ///     default.
  ///   - body: Synchronous effect code, given the value before this change
  ///     and the value after it.
  public func watch<Value>(
    _ valueReference: Cog<Value>.Projection,
    initial: CogWatchStart,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ body: @escaping @MainActor (Value, Value) -> Void
  ) {
    register { cogs in
      cogs.watchTracked(
        label: CogLabel(name: composed(name), fileID: fileID, line: line),
        initial: initial,
        read: { c in c[valueReference] },
        body: body
      )
    }
  }
}

// MARK: - Tasks

extension MechanismController {
  /// Starts a named unstructured task owned by this controller's scope.
  ///
  /// The task belongs to the scope that started it and receives cooperative
  /// cancellation when the scope ends. Its name includes the mechanism name.
  /// For example, `hourlyRefresh` under `Weather` becomes
  /// `Weather.hourlyRefresh` in Apple task diagnostics.
  ///
  /// Time-based work injects a `Clock` so tests control it. Task bodies call
  /// ops, so writes keep useful names in debug history. A long-running body
  /// captures its controller weakly and promotes it around each unit of graph
  /// work; this lets scope teardown release the controller even if cancelled
  /// work has not cooperatively returned yet.
  ///
  /// The task begins on the MainActor and first checks cancellation. The
  /// operation then runs with the isolation expressed at its declaration.
  /// Errors are stored in the returned task and are not converted into Cog
  /// state or debug-history events.
  ///
  /// - Parameters:
  ///   - name: The task name, composed under the mechanism's name for Apple
  ///     task diagnostics.
  ///   - operation: The throwing async work to start and own.
  /// - Returns: The exact task owned by the scope, allowing callers to await
  ///   its result when needed.
  @discardableResult
  public func task(
    name: String,
    _ operation: sending @escaping @isolated(any) () async throws -> Void
  ) -> Task<Void, any Error> {
    scope.task(name: "\(namePath).\(name)", operation)
  }
}

// MARK: - Gated scopes

extension MechanismController {
  /// Runs a nested scope while a Bool cog reads true.
  ///
  /// When the gate is true, `body` runs once with a fresh sub-controller and
  /// makes its registrations live. A turn that settles the gate to false ends
  /// those registrations and cancels their tasks in normal flush order. The
  /// next rise starts from a new scope. State that must survive a close and
  /// reopen belongs in the graph.
  ///
  /// The body is not a reaction; only the gate can reopen the scope. Reads in
  /// `watch` or `run` track their own dependencies, while direct `peek` reads do
  /// not retrigger the scope. Sub-controllers support nested `whenever` scopes,
  /// and their names keep composing.
  ///
  /// - Parameters:
  ///   - gate: The automatic Bool that opens and closes this scope.
  ///   - name: What Cog should call this scope, composed under the
  ///     mechanism's name for the gate's history entries and the scope's
  ///     registrations. An unnamed scope composes its registrations directly
  ///     under this controller's name.
  ///   - fileID: The registration's file for diagnostics. Leave this at its
  ///     default.
  ///   - line: The registration's line for diagnostics. Leave this at its
  ///     default.
  ///   - body: Registration code run at each rise with that cycle's fresh
  ///     sub-controller.
  public func whenever(
    _ gate: Cog<Bool>,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ body: @escaping @MainActor (MechanismController) -> Void
  ) {
    wheneverTracked(
      name: name, fileID: fileID, line: line,
      read: { c in c[gate] },
      body: body
    )
  }

  /// Runs a nested scope while a manual Bool source reads true.
  ///
  /// Semantics match the automatic-gate overload exactly.
  public func whenever(
    _ gate: Cog<Bool>.Manual,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ body: @escaping @MainActor (MechanismController) -> Void
  ) {
    wheneverTracked(
      name: name, fileID: fileID, line: line,
      read: { c in c[gate] },
      body: body
    )
  }

  /// Runs a nested scope while a read-only Bool projection reads true.
  ///
  /// Semantics match the automatic-gate overload exactly.
  public func whenever(
    _ gate: Cog<Bool>.Projection,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ body: @escaping @MainActor (MechanismController) -> Void
  ) {
    wheneverTracked(
      name: name, fileID: fileID, line: line,
      read: { c in c[gate] },
      body: body
    )
  }

  /// Implements every `whenever` overload over one tracked Bool read.
  ///
  /// The gate is an ordinary watch with `initial: .run`, so an
  /// already-true gate opens the scope during registration and equal writes
  /// stay quiet. The open child scope registers with this controller's scope
  /// for cascade cancellation: a parent that ends tears open descendants
  /// down with it, while a gate that closes normally cancels and disowns its
  /// child itself.
  private func wheneverTracked(
    name: String?,
    fileID: StaticString,
    line: UInt,
    read: @escaping @MainActor (ReactionReader) -> Bool,
    body: @escaping @MainActor (MechanismController) -> Void
  ) {
    let childPath = composed(name) ?? namePath
    let parentScope = scope

    // Captured by the gate watch: the one open child per gate, between runs.
    var activeChild: MechanismScope?

    register { cogs in
      cogs.watchTracked(
        label: CogLabel(name: composed(name), fileID: fileID, line: line),
        initial: .run,
        read: read
      ) { [weak cogtext = cogs] _, isOpen in
        if isOpen {
          guard activeChild == nil, let cogtext else { return }
          let childScope = MechanismScope()
          let child = MechanismController(
            cogs: cogtext, namePath: childPath, scope: childScope)
          childScope.retain(controller: child)
          parentScope.adopt(child: childScope)
          activeChild = childScope
          body(child)
        } else {
          guard let childScope = activeChild else { return }
          activeChild = nil
          parentScope.disown(child: childScope)
          childScope.cancel()
        }
      }
    }
  }
}

// MARK: - Status lens

extension MechanismController {
  /// The lens for watching and peeking async request lifecycles.
  ///
  /// Accessing the property is inert; only the lens's operations touch the
  /// graph. The lens carries the same rules as `Cogs.status`: it exists only
  /// for async references, and asking it about synchronous state is a type
  /// error.
  public var status: Status {
    Status(controller: self)
  }

  /// The status-reading facet of one controller.
  @MainActor
  public struct Status {
    /// The controller whose scope owns this lens's registrations.
    internal let controller: MechanismController

    /// Registers a reaction that watches an async cog's full status.
    ///
    /// Installation settles the exact async state, records it as the watch's
    /// one tracked dependency, and captures that status as the baseline. A
    /// first read can start work, so the baseline normally has
    /// ``CogStatus/kind`` equal to ``CogStatus/Kind/pending``.
    /// ``CogWatchStart/skip`` suppresses only the initial body call; it does
    /// not skip the read or subscription.
    ///
    /// Pending, success, and failure are published in separate turns. After
    /// each such turn settles, the watch runs in registration order and
    /// receives its previous and current status. This includes an equal-success
    /// reload that a value watch would gate away. The
    /// registration holds a `whileObserved` lease on the async state; the end
    /// of the controller's scope cancels the watch and begins ordinary grace
    /// when no other durable consumer remains.
    ///
    /// - Parameters:
    ///   - valueReference: The async value whose full status to watch.
    ///   - initial: Whether installation calls `body` with the baseline
    ///     status as both arguments.
    ///   - name: What Cog should call this effect in debug history, composed
    ///     under the mechanism's name. Defaults to the file and line of the
    ///     registration.
    ///   - fileID: The registration's file for diagnostics. Leave this at
    ///     its default.
    ///   - line: The registration's line for diagnostics. Leave this at its
    ///     default.
    ///   - body: Synchronous effect code, given the status before this change
    ///     and the status after it.
    public func watch<Value>(
      _ valueReference: Cog<Value>.Async,
      initial: CogWatchStart,
      name: String? = nil,
      fileID: StaticString = #fileID,
      line: UInt = #line,
      _ body: @escaping @MainActor (CogStatus<Value>, CogStatus<Value>) -> Void
    ) {
      controller.register { cogs in
        cogs.watchTracked(
          label: CogLabel(
            name: controller.composed(name), fileID: fileID, line: line),
          initial: initial,
          read: { c in c.status[valueReference] },
          body: body
        )
      }
    }

    /// Reads an async cog's current status without creating a dependency
    /// edge.
    ///
    /// See `Cogs.Status.peek(_:)`; both capabilities share the demand and
    /// grace contract exactly.
    ///
    /// - Parameter valueReference: The async declaration and optional key to
    ///   inspect.
    /// - Returns: Its current full status, beginning with pending on first
    ///   demand.
    public func peek<Value>(_ valueReference: Cog<Value>.Async) -> CogStatus<Value> {
      controller.requiredRuntime.status.peek(valueReference)
    }
  }
}

// MARK: - Ops

extension MechanismController: CogOps {
  /// Opens one turn attributed to this mechanism.
  ///
  /// The turn name composes under the controller's name path, so history
  /// records which mechanism asked for the write, such as
  /// `Weather.checkWeather` instead of `checkWeather`. After the runtime is gone, the turn
  /// is inert: there is no graph left to write.
  public func turn(named name: String, _ body: @escaping (Writer) -> Void) {
    guard let cogtext else { return }
    cogtext.turn(named: "\(namePath).\(name)", body)
  }

  /// Reads a source without creating a dependency edge; see ``Cogs/peek(_:)-(Cog<Value>.Manual)``.
  ///
  /// An `operate`-time read never becomes a dependency, because `operate` is
  /// registration, not a reaction.
  public func peek<Value>(_ valueReference: Cog<Value>.Manual) -> Value {
    requiredRuntime.peek(valueReference)
  }

  /// Reads an automatic cog without creating a dependency edge.
  public func peek<Value>(_ valueReference: Cog<Value>) -> Value {
    requiredRuntime.peek(valueReference)
  }

  /// Reads an async cog's current value without creating a dependency edge.
  public func peek<Value>(_ valueReference: Cog<Value>.Async) -> Value {
    requiredRuntime.peek(valueReference)
  }

  /// Reads a source's read-only projection without creating a dependency
  /// edge.
  public func peek<Value>(_ valueReference: Cog<Value>.Projection) -> Value {
    requiredRuntime.peek(valueReference)
  }

  /// Demands one fresh generation of an async value; see ``Cogs/refresh(_:)``.
  @discardableResult
  public func refresh<Value>(_ valueReference: Cog<Value>.Async) -> CogRefresh<Value> {
    requiredRuntime.refresh(valueReference)
  }
}
