/// The capability a mechanism's `operate` receives: its entire relationship
/// with the graph.
///
/// The controller carries registration (``run(fileID:line:_:)``,
/// `watch`, ``task(name:_:)``, and gated ``whenever`` scopes), untracked
/// ``peek`` reads, and the shared ``CogOperating`` op surface. There is
/// deliberately no raw ``Cogs`` here: a mechanism that could reach the runtime
/// could also leak it past its own discipline, and routing every act through
/// the controller is what makes attribution and isolated testing exact (§6.2).
///
/// A controller is a final-class lifetime capability retained by its scope, so
/// asynchronous and delegate-driven work may capture it weakly. It does not
/// own the app runtime. When its scope ends — runtime teardown for a bootstrap
/// mechanism, a falling gate for a `whenever` sub-controller — the runtime
/// cancels the scope's registrations and tasks and releases the controller;
/// a `[weak m]` callback then fails promotion and returns. Storing a
/// controller strongly in an external engine is unsupported, because it would
/// let the engine outlive the lifetime that authorized its graph access.
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
  /// registrations. After the runtime deinitializes, registration and commit
  /// calls become inert.
  private weak var cogtext: Cogs?

  /// The composed attribution name: the mechanism's name, extended by each
  /// named `whenever` scope this controller sits inside.
  internal let namePath: String

  /// The scope that owns every registration this controller makes.
  private let scope: MechanismScope

  /// Creates the capability for one mechanism or `whenever` scope.
  ///
  /// Only bootstrap and an opening gate construct controllers; the scope
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
  /// Registrations and commits after runtime teardown simply do nothing, but
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
  /// The runtime owns registrations in call order — across mechanisms, array
  /// order at bootstrap. A turn marks only reactions reachable from changed
  /// state; the flush then runs those reactions after their dependencies
  /// settle and leaves unrelated registrations quiet. Outside a flush the
  /// initial run completes before this method returns. A registration made
  /// during a flush joins that reaction queue's tail instead of re-entering
  /// its caller.
  ///
  /// The registration lives until this controller's scope ends; there is no
  /// public token. A shorter lifetime is a ``whenever`` gate expressed in
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
  ///     and the value after it. The body runs on the MainActor; commits it
  ///     requests during a flush become later FIFO turns.
  public func watch<Value>(
    _ valueReference: ManualCog<Value>,
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

  /// Registers a reaction that watches one derived cog and receives its old
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
  /// derived state; the end of this controller's scope cancels both and may
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
  ///     and the value after it. The body runs on the MainActor; commits it
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
  ///     and the value after it. The body runs on the MainActor; commits it
  ///     requests during a flush become later FIFO turns.
  public func watch<Value>(
    _ valueReference: AsyncCog<Value>,
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
    _ valueReference: CogProjection<Value>,
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
  /// cancellation when that scope ends. Its name composes under the
  /// mechanism's — a `hourlyRefresh` task in the `Weather` mechanism appears
  /// as `Weather.hourlyRefresh` in Apple task diagnostics.
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
  /// A lifetime shorter than the app is graph state, not a registration
  /// ceremony. When the gate reads true — at registration or after a later
  /// turn — `body` runs once with a fresh sub-controller and its
  /// registrations become live. When a turn settles the gate to false,
  /// everything registered through that sub-controller ends: reactions
  /// unregister and tasks cancel. The teardown replaces a reaction run in
  /// the ordinary flush order, so effects never observe a half-closed scope.
  /// The next rise runs `body` again from scratch; nothing survives a
  /// down-and-up cycle, so a scope that needs continuity keeps it in graph
  /// state.
  ///
  /// The body itself is not a reaction: the gate is the scope's only tracked
  /// dependency, and reads inside the body other than through its own
  /// `watch`/`run` registrations use the sub-controller's `peek` and never
  /// re-trigger the scope. Scopes nest — the sub-controller offers this full
  /// controller surface, including `whenever` — and names continue to
  /// compose.
  ///
  /// - Parameters:
  ///   - gate: The derived Bool that opens and closes this scope.
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
  /// Semantics match the derived-gate overload exactly.
  public func whenever(
    _ gate: ManualCog<Bool>,
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
  /// Semantics match the derived-gate overload exactly.
  public func whenever(
    _ gate: CogProjection<Bool>,
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
    /// receives its previous and current status — including an equal-success
    /// reload the value watch beside this lens would gate away. The
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
      _ valueReference: AsyncCog<Value>,
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
    public func peek<Value>(_ valueReference: AsyncCog<Value>) -> CogStatus<Value> {
      controller.requiredRuntime.status.peek(valueReference)
    }
  }
}

// MARK: - Ops

extension MechanismController: CogOperating {
  /// Opens one turn attributed to this mechanism.
  ///
  /// The turn name composes under the controller's name path, so history
  /// records which mechanism asked for the write — `Weather.checkWeather`
  /// rather than a bare `checkWeather`. After the runtime is gone the commit
  /// is inert: there is no graph left to write.
  public func commit(named name: String, _ body: @escaping (Writer) -> Void) {
    guard let cogtext else { return }
    cogtext.commit(named: "\(namePath).\(name)", body)
  }

  /// Reads a source without creating a dependency edge; see ``Cogs/peek(_:)-swift.method``.
  ///
  /// An `operate`-time read never becomes a dependency, because `operate` is
  /// registration, not a reaction.
  public func peek<Value>(_ valueReference: ManualCog<Value>) -> Value {
    requiredRuntime.peek(valueReference)
  }

  /// Reads a derived cog without creating a dependency edge.
  public func peek<Value>(_ valueReference: Cog<Value>) -> Value {
    requiredRuntime.peek(valueReference)
  }

  /// Reads an async cog's current value without creating a dependency edge.
  public func peek<Value>(_ valueReference: AsyncCog<Value>) -> Value {
    requiredRuntime.peek(valueReference)
  }

  /// Reads a source's read-only projection without creating a dependency
  /// edge.
  public func peek<Value>(_ valueReference: CogProjection<Value>) -> Value {
    requiredRuntime.peek(valueReference)
  }

  /// Demands one fresh generation of an async value; see ``Cogs/refresh(_:)``.
  @discardableResult
  public func refresh<Value>(_ valueReference: AsyncCog<Value>) -> CogRefresh<Value> {
    requiredRuntime.refresh(valueReference)
  }
}
