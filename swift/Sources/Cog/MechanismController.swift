/// The graph capability passed to a mechanism's `operate` method.
///
/// It can register `run`, `watch`, `task`, and shorter-lived `scope` children.
/// It also has untracked `peek` reads and the shared ``CogOps`` surface. It
/// cannot expose the raw ``Cogs``. Keeping all access on this controller
/// preserves attribution and lets tests isolate a mechanism (§6.2).
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
///
/// ## Retirement revokes authority
///
/// A weak capture is an ownership convention, not the safety mechanism. Work
/// can promote the reference and then suspend, and a retained ``status`` lens
/// keeps a controller alive on its own. So retirement — a `scope` whose
/// identity changed, a parent that ended, or runtime teardown — revokes what
/// this object can do rather than merely asking its tasks to stop:
///
/// | Operation through a retired controller | Behavior                                             |
/// | -------------------------------------- | ---------------------------------------------------- |
/// | `turn`, and every op built on it       | Inert before the writer body runs or work is enqueued |
/// | A turn already waiting in the FIFO     | Rejected at its execution point, publishing nothing   |
/// | `run`, `watch`, `status.watch`         | Inert before any baseline read, callback, or lease    |
/// | Every `scope` family                   | Inert before the selector is read or a body runs      |
/// | `task`                                 | A cancelled task; the operation never starts          |
/// | `peek`, `status.peek`, `refresh`       | Trap with a diagnostic naming the operation and scope |
///
/// Reads trap because the signature cannot honestly manufacture a `Value`, and
/// a rejected `refresh` must not fabricate ``CogRefresh/Outcome/released`` while
/// the shared state it names is still alive. Ordinary late work should not need
/// them: publish a completion through a receipt-bearing op, whose reads happen
/// inside the guarded writer body, and use ``ifLive(_:)`` when a genuine
/// post-suspension read or follow-up demand is unavoidable.
///
/// Revocation covers operations routed through this controller. It cannot make
/// an arbitrary `CogOps` extension inert: statements in that method before it
/// reaches a Cog primitive are ordinary Swift and still run. Nor can it unwind a
/// synchronous frame that retires its own scope midway; later primitives in that
/// frame observe retirement, but the frame itself continues.
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
  /// named `scope` child this controller sits inside.
  internal let namePath: String

  /// The scope that owns every registration this controller makes.
  ///
  /// Named for the ownership relationship rather than the registration verb so
  /// the `scope(_:name:fileID:line:_:)` family can take the plain name.
  private let ownedScope: MechanismScope

  /// Creates the capability for one mechanism or one `scope` child.
  ///
  /// Only assembly and an opening selector construct controllers; the scope
  /// retains the result for exactly the lifetime it authorizes.
  internal init(cogs: Cogs, namePath: String, scope: MechanismScope) {
    self.cogtext = cogs
    self.namePath = namePath
    self.ownedScope = scope
  }

  /// Whether this controller may still act on the graph.
  ///
  /// False once its scope is retired or the runtime is gone. Retirement is
  /// marked across a whole subtree before any teardown work runs, so this stays
  /// correct for a descendant whose own cleanup pass has not been reached yet.
  private var isLive: Bool {
    cogtext != nil && !ownedScope.isRetired
  }

  /// Extends this controller's attribution path with one registration name.
  private func composed(_ name: String?) -> String? {
    name.map { "\(namePath).\($0)" }
  }

  /// Registers `make`'s token with the graph and hands it to this scope.
  ///
  /// The liveness check comes first, before `make` runs. That ordering is the
  /// point: `make` reads a baseline, may deliver an initial callback, and can
  /// acquire a lease, so checking only when the finished token reaches
  /// ``MechanismScope/add(_:)`` would let a retired scope run application code
  /// once before rejecting its registration. The terminal check in `add`
  /// remains as the ownership defense for a body that retires its own scope
  /// while this registration is still initializing.
  private func register(_ make: (Cogs) -> ReactionToken) {
    guard let cogtext, !ownedScope.isRetired else { return }
    ownedScope.add(make(cogtext))
  }

  /// The runtime for a value-producing call, which cannot be inert.
  ///
  /// Registrations and turns after retirement simply do nothing, but a read
  /// must return a value and no honest value exists. The two diagnostics are
  /// kept apart because the repairs differ: a dead runtime means work outlived
  /// the whole graph, while a retired scope means work outlived the lifetime
  /// that authorized it while the app runs on.
  ///
  /// - Parameter operation: The public spelling to name in the diagnostic.
  private func requiredRuntime(for operation: String) -> Cogs {
    guard let cogtext else {
      // `fatalError`, not `preconditionFailure`: an optimized build drops
      // `preconditionFailure` messages, and this misuse needs its diagnosis.
      fatalError(
        """
        The \(namePath) mechanism called `\(operation)` through its controller \
        after the app runtime was gone. Capture the controller weakly — \
        `[weak m]` — and promote it around each unit of graph work so cancelled \
        work returns instead of reading a released graph.
        """
      )
    }
    guard !ownedScope.isRetired else {
      fatalError(
        """
        The \(namePath) scope called `\(operation)` after it was retired. The \
        app runtime is still alive, but this scope's lifetime ended, so there \
        is no value it can honestly return. Publish late results through a \
        receipt-bearing op and validate them inside its writer body, which a \
        retired scope never reaches, or wrap a genuinely needed read in \
        `m.ifLive { ... }`, which returns nil instead of trapping.
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
  /// public token. A shorter lifetime is a
  /// ``scope(_:name:fileID:line:_:)-(Cog<Bool>,_,_,_,_)`` child whose condition
  /// or identity lives in state.
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
  /// A task requested through a retired controller preserves the return type
  /// and nothing else: the returned task is already cancelled, its operation
  /// never starts, and the retired scope does not retain it.
  ///
  /// - Returns: The exact task owned by the scope, allowing callers to await
  ///   its result when needed.
  @discardableResult
  public func task(
    name: String,
    _ operation: sending @escaping @isolated(any) () async throws -> Void
  ) -> Task<Void, any Error> {
    ownedScope.task(name: "\(namePath).\(name)", operation)
  }
}

// MARK: - Scopes

extension MechanismController {
  /// Runs a nested scope while a Bool cog reads true.
  ///
  /// When the gate is true, `body` runs once with a fresh sub-controller and
  /// makes its registrations live. A turn that settles the gate to false retires
  /// those registrations and cancels their tasks in normal flush order. The next
  /// rise opens a fresh scope. State that must survive a close and reopen
  /// belongs in the graph.
  ///
  /// A Bool gate is the special case of the identity form in which there is
  /// either no lifetime or one fixed lifetime, and it shares that
  /// implementation exactly. It cannot express replacement: `true → true` is
  /// always the same lifetime, however much else changed. Work that must be
  /// replaced when a session, workflow, or presentation is replaced selects an
  /// optional identity instead — see
  /// ``scope(_:name:fileID:line:_:)-(Cog<Identity?>,_,_,_,_)``.
  ///
  /// The body is not a reaction; only the gate can reopen the scope. Reads in
  /// `watch` or `run` track their own dependencies, while direct `peek` reads do
  /// not retrigger the scope. Sub-controllers support nested scopes of either
  /// family, and their names keep composing.
  ///
  /// - Parameters:
  ///   - gate: The automatic Bool that opens and retires this scope.
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
  public func scope(
    _ gate: Cog<Bool>,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ body: @escaping @MainActor (MechanismController) -> Void
  ) {
    scopeTracked(
      name: name, fileID: fileID, line: line,
      read: { c in c[gate] ? CogGateIdentity() : nil },
      body: { _, child in body(child) }
    )
  }

  /// Runs a nested scope while a manual Bool source reads true.
  ///
  /// Semantics match the automatic-gate overload exactly.
  public func scope(
    _ gate: Cog<Bool>.Manual,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ body: @escaping @MainActor (MechanismController) -> Void
  ) {
    scopeTracked(
      name: name, fileID: fileID, line: line,
      read: { c in c[gate] ? CogGateIdentity() : nil },
      body: { _, child in body(child) }
    )
  }

  /// Runs a nested scope while a read-only Bool projection reads true.
  ///
  /// Semantics match the automatic-gate overload exactly.
  public func scope(
    _ gate: Cog<Bool>.Projection,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ body: @escaping @MainActor (MechanismController) -> Void
  ) {
    scopeTracked(
      name: name, fileID: fileID, line: line,
      read: { c in c[gate] ? CogGateIdentity() : nil },
      body: { _, child in body(child) }
    )
  }

  /// Runs a nested scope owned by whichever lifetime an optional identity
  /// selects.
  ///
  /// A Bool says whether work should exist. An identity additionally says
  /// *which* lifetime owns it, which is what lets one active lifetime be
  /// replaced by another with no artificial gap in between:
  ///
  /// ```swift
  /// m.scope(activeSessionCog, name: "session") { session, s in
  ///   let credentials = credentialProvider.bound(to: session)
  ///   s.watch(pendingUploadsCog, initial: .run, name: "sync") { _, uploads in
  ///     sync.enqueue(uploads, using: credentials)
  ///   }
  /// }
  /// ```
  ///
  /// The transitions, all decided against settled values:
  ///
  /// | Observation                          | Result                                                   |
  /// | ------------------------------------ | -------------------------------------------------------- |
  /// | Initially `nil`                      | Install the selector; open no child                       |
  /// | Initially `A`                        | Open `A` once, under ordinary initial-registration order  |
  /// | `nil → A`                            | Open a fresh child and run `body` once                    |
  /// | `A → A`, including a distinct equal   | Keep the same child; no restart, no second registration   |
  /// | `A → B`                              | Retire `A`, then open `B` at the selector's flush position |
  /// | `A → nil`                            | Retire `A`; open nothing                                  |
  /// | `A → nil → A` in completed turns     | A second, different `A` child; the first stays retired     |
  /// | One turn staging `A → B → A`          | Nothing happens: only the settled value is a transition    |
  /// | Parent or runtime teardown           | Retire this child and every descendant, permanently        |
  ///
  /// Equality is checked here as well as by the graph, so a source configured
  /// to publish equal values cannot restart an unchanged lifetime. The
  /// obligation runs the other way too: the selected cog must expose lifetime
  /// changes faithfully. A custom `==` that reports two genuinely different
  /// lifetimes as equal hides a replacement this scope can never perform.
  ///
  /// Mint an identity when the domain operation that creates the lifetime
  /// happens — signing in, opening a screen, starting a workflow — and keep it
  /// in state. Do not mint one while the selector recomputes: that turns
  /// recomputation into a new lifetime. Signing the same account in again is a
  /// new epoch; refreshing a token is not. Search text and filters usually
  /// select a *request* inside a presentation, not a new presentation.
  ///
  /// `body` is registration code, not a reaction. It runs once per opening,
  /// synchronously, and the selected identity is the scope's only lifetime
  /// dependency: `peek` reads inside it do not restart the scope, while child
  /// `run` and `watch` registrations track their own dependencies normally.
  ///
  /// - Parameters:
  ///   - identity: The automatic optional identity that selects this scope's
  ///     lifetime. `nil` means no lifetime and therefore no child.
  ///   - name: What Cog should call this scope, composed under the mechanism's
  ///     name. Successive lifetimes share the name; they are separate
  ///     instances, not a renamed one.
  ///   - fileID: The registration's file for diagnostics. Leave this at its
  ///     default.
  ///   - line: The registration's line for diagnostics. Leave this at its
  ///     default.
  ///   - body: Registration code run once per opening, given the exact
  ///     nonoptional identity that opened this child and its fresh
  ///     sub-controller.
  public func scope<Identity: Equatable>(
    _ identity: Cog<Identity?>,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ body: @escaping @MainActor (Identity, MechanismController) -> Void
  ) {
    scopeTracked(
      name: name, fileID: fileID, line: line,
      read: { c in c[identity] },
      body: body
    )
  }

  /// Runs a nested scope owned by the lifetime a manual optional identity
  /// source selects.
  ///
  /// Semantics match the automatic-identity overload exactly.
  public func scope<Identity: Equatable>(
    _ identity: Cog<Identity?>.Manual,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ body: @escaping @MainActor (Identity, MechanismController) -> Void
  ) {
    scopeTracked(
      name: name, fileID: fileID, line: line,
      read: { c in c[identity] },
      body: body
    )
  }

  /// Runs a nested scope owned by the lifetime a read-only optional identity
  /// projection selects.
  ///
  /// Semantics match the automatic-identity overload exactly.
  public func scope<Identity: Equatable>(
    _ identity: Cog<Identity?>.Projection,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ body: @escaping @MainActor (Identity, MechanismController) -> Void
  ) {
    scopeTracked(
      name: name, fileID: fileID, line: line,
      read: { c in c[identity] },
      body: body
    )
  }

  /// Implements every single-identity `scope` overload over one tracked read.
  ///
  /// The selector is an ordinary watch with `initial: .run`, so an identity
  /// already present at registration opens its child during registration, and
  /// registration made during a flush joins that flush's reaction tail instead
  /// of reentering its caller. Replacement uses the same path, so a new child's
  /// first reactions also join the tail rather than overtaking work already
  /// queued.
  ///
  /// The two captured locals are the whole state machine: which identity is
  /// open, and which scope object serves it. Comparing the selected identity
  /// against the open one here — not only relying on the graph's equality gate
  /// — is what keeps a source that republishes an equal value from restarting
  /// an unchanged lifetime.
  ///
  /// The open child registers with this controller's scope for cascade
  /// retirement: a parent that ends tears every open descendant down with it,
  /// while a selector that replaces or drops its identity retires and disowns
  /// its own child.
  private func scopeTracked<Identity: Equatable>(
    name: String?,
    fileID: StaticString,
    line: UInt,
    read: @escaping @MainActor (ReactionReader) -> Identity?,
    body: @escaping @MainActor (Identity, MechanismController) -> Void
  ) {
    let childPath = composed(name) ?? namePath
    let parentScope = ownedScope

    // Captured by the selector watch: the one open child and the identity it
    // belongs to, between runs.
    var openIdentity: Identity?
    var openChild: MechanismScope?

    register { cogs in
      cogs.watchTracked(
        label: CogLabel(name: composed(name), fileID: fileID, line: line),
        initial: .run,
        read: read
      ) { [weak cogtext = cogs] _, selected in
        if let selected, let openIdentity, selected == openIdentity { return }

        if let retiring = openChild {
          openChild = nil
          openIdentity = nil
          parentScope.disown(child: retiring)
          retiring.cancel()
        }

        guard let selected, !parentScope.isRetired, let cogtext else { return }
        let childScope = MechanismScope()
        let child = MechanismController(
          cogs: cogtext, namePath: childPath, scope: childScope)
        childScope.retain(controller: child)
        parentScope.adopt(child: childScope)
        openChild = childScope
        openIdentity = selected
        body(selected, child)
      }
    }
  }
}

// MARK: - Scopes over a collection of identities

extension MechanismController {
  /// Runs one nested scope per stable identity in a collection, reconciled as
  /// the collection changes.
  ///
  /// One selected identity fits a session, a current workflow, or a fixed sheet
  /// slot. A navigation stack is not that shape: entries arrive and depart in
  /// any order, and two entries can name the same resource while owning
  /// separate work. Registering a selector per entry would work, but nothing
  /// would ever remove those selectors — the parent would accumulate one
  /// dormant watch for every entry the app has ever pushed. This overload is
  /// the collection form of exactly the same child lifecycle: one selector
  /// registration in total, and one child per live identity.
  ///
  /// ```swift
  /// m.scope(each: openPresentationIDsCog, name: "presentation") { id, s in
  ///   s.watch(searchQueryCogs[id], initial: .skip, name: "search") { _, query in
  ///     search.run(query, for: id)
  ///   }
  /// }
  /// ```
  ///
  /// Reconciliation compares membership, never position:
  ///
  /// - An identity that was not present opens a fresh child and runs `body`
  ///   once, receiving that exact identity.
  /// - An identity that is still present keeps its **exact** child instance,
  ///   its registrations, its tasks, and its leases. Nothing reruns.
  /// - An identity that has gone retires its child, cancelling its
  ///   registrations and tasks like any other retirement.
  /// - Reordering alone changes nothing at all: every identity is still
  ///   present, so no child is retired, opened, or restarted.
  /// - Removing an identity and adding it back in a later completed turn opens
  ///   a second, different child. Nothing from the first is revived. Within one
  ///   atomic turn only the settled membership counts, so an identity that
  ///   leaves and returns before the turn publishes never left.
  ///
  /// Order is deterministic. Departed children retire first, in the order they
  /// were opened; added children then open in the order they appear in the new
  /// collection, so their registrations hold that order. Retiring this
  /// controller's own scope retires every child, and repeated teardown is safe.
  ///
  /// Identities must be distinct. A collection containing the same identity
  /// twice describes two lifetimes that cannot be told apart — neither
  /// reconciliation nor retirement could say which one a later removal meant —
  /// so it fails in debug and release builds rather than silently owning one
  /// child for two entries.
  ///
  /// This owns registrations, and only registrations. Retiring a child ends its
  /// effects; it issues no writes and reclaims no state. What a departed entry
  /// leaves in the graph is governed by that state's own declared retention.
  ///
  /// - Parameters:
  ///   - identities: The automatic collection of live identities. Order is not
  ///     part of the lifetime; membership is.
  ///   - name: What Cog should call these scopes, composed under the
  ///     mechanism's name. Every child shares it.
  ///   - fileID: The registration's file for diagnostics. Leave this at its
  ///     default.
  ///   - line: The registration's line for diagnostics. Leave this at its
  ///     default.
  ///   - body: Registration code run once per opened identity, given that
  ///     identity and its own fresh sub-controller.
  public func scope<Identity: Hashable>(
    each identities: Cog<[Identity]>,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ body: @escaping @MainActor (Identity, MechanismController) -> Void
  ) {
    scopeTracked(
      eachNamed: name, fileID: fileID, line: line,
      read: { c in c[identities] },
      body: body
    )
  }

  /// Runs one nested scope per identity in a manual collection source.
  ///
  /// Semantics match the automatic-collection overload exactly.
  public func scope<Identity: Hashable>(
    each identities: Cog<[Identity]>.Manual,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ body: @escaping @MainActor (Identity, MechanismController) -> Void
  ) {
    scopeTracked(
      eachNamed: name, fileID: fileID, line: line,
      read: { c in c[identities] },
      body: body
    )
  }

  /// Runs one nested scope per identity in a read-only collection projection.
  ///
  /// Semantics match the automatic-collection overload exactly.
  public func scope<Identity: Hashable>(
    each identities: Cog<[Identity]>.Projection,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ body: @escaping @MainActor (Identity, MechanismController) -> Void
  ) {
    scopeTracked(
      eachNamed: name, fileID: fileID, line: line,
      read: { c in c[identities] },
      body: body
    )
  }

  /// Implements every `scope(each:)` overload over one tracked read.
  ///
  /// `Hashable` is required here and only here. The single-identity form owns
  /// at most one child and needs nothing but `==`; this form reconciles
  /// membership on every published collection and detects duplicates, both of
  /// which are set operations. That is an independent constraint on an
  /// independent operation, not a tightening of the scalar family.
  ///
  /// One watch installs for the whole family, so a collection that grows and
  /// shrinks forever adds no registrations of its own — only the children the
  /// current membership justifies. `openChildren` keeps opening order so
  /// retirement is deterministic, and it is short by construction: it holds
  /// exactly the live identities.
  private func scopeTracked<Identity: Hashable>(
    eachNamed name: String?,
    fileID: StaticString,
    line: UInt,
    read: @escaping @MainActor (ReactionReader) -> [Identity],
    body: @escaping @MainActor (Identity, MechanismController) -> Void
  ) {
    let childPath = composed(name) ?? namePath
    let parentScope = ownedScope

    // Captured by the selector watch: the live children in opening order.
    var openChildren: [(identity: Identity, scope: MechanismScope)] = []

    register { cogs in
      cogs.watchTracked(
        label: CogLabel(name: composed(name), fileID: fileID, line: line),
        initial: .run,
        read: read
      ) { [weak cogtext = cogs] _, selected in
        var selectedSet: Set<Identity> = []
        selectedSet.reserveCapacity(selected.count)
        for identity in selected where !selectedSet.insert(identity).inserted {
          // `fatalError`, not `preconditionFailure`: an optimized build drops
          // `preconditionFailure` messages, and this misuse needs its
          // diagnosis.
          fatalError(
            """
            The \(childPath) scope was given the identity \
            \(String(reflecting: identity)) twice in one collection. Each \
            scope in this family owns one lifetime, so two entries sharing an \
            identity could not be opened, retired, or attributed separately. \
            Mint a distinct identity when each lifetime is created.
            """
          )
        }

        var survivors: [(identity: Identity, scope: MechanismScope)] = []
        survivors.reserveCapacity(openChildren.count)
        for entry in openChildren {
          if selectedSet.contains(entry.identity) {
            survivors.append(entry)
            continue
          }
          parentScope.disown(child: entry.scope)
          entry.scope.cancel()
        }
        openChildren = survivors

        guard !parentScope.isRetired, let cogtext else { return }
        var liveSet: Set<Identity> = []
        liveSet.reserveCapacity(openChildren.count)
        for entry in openChildren {
          liveSet.insert(entry.identity)
        }

        for identity in selected where !liveSet.contains(identity) {
          let childScope = MechanismScope()
          let child = MechanismController(
            cogs: cogtext, namePath: childPath, scope: childScope)
          childScope.retain(controller: child)
          parentScope.adopt(child: childScope)
          openChildren.append((identity: identity, scope: childScope))
          body(identity, child)
        }
      }
    }
  }
}

/// The one fixed identity a Bool gate selects while it reads true.
///
/// A Bool lifetime is the identity family with exactly two states: no identity,
/// or this one. Mapping it here rather than at the call site is what keeps
/// callers from inventing a sentinel optional cog for an ordinary condition,
/// and keeps both families on one lifecycle implementation. It is deliberately
/// private and never reaches a Bool registration body, which receives only its
/// controller.
private struct CogGateIdentity: Equatable {}

// MARK: - Status lens

extension MechanismController {
  /// The lens for watching and peeking async request lifecycles.
  ///
  /// Accessing the property is inert; only the lens's operations touch the
  /// graph. The lens carries the same rules as `Cogs.status`: it exists only
  /// for async references, and asking it about synchronous state is a type
  /// error.
  ///
  /// A retained lens is a retained controller, so it obeys the same retirement
  /// rules: its `watch` is inert after retirement and its `peek` traps.
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
      controller.requiredRuntime(for: "status.peek").status.peek(valueReference)
    }
  }
}

// MARK: - Ops

extension MechanismController: CogOps {
  /// Opens one turn attributed to this mechanism.
  ///
  /// The turn name composes under the controller's name path, so history
  /// records which mechanism asked for the write, such as
  /// `Weather.checkWeather` instead of `checkWeather`.
  ///
  /// A turn requested after the runtime is gone or this scope was retired is
  /// inert. Nothing is enqueued and `body` never runs, so a stale completion
  /// cannot mutate the state its replacement now owns. A turn requested while a
  /// flush is in progress waits in the ordinary FIFO and is checked again
  /// immediately before it would start: if an entry ahead of it retired this
  /// scope, it is discarded without opening a turn, advancing the revision, or
  /// recording history. A turn that reaches its execution point first is valid
  /// and stays valid; retirement is not a retroactive rollback.
  ///
  /// This inertness belongs to the primitive, not to the op that called it. An
  /// op is an ordinary method: the statements before it reaches `turn` still
  /// run. Put the receipt validation and the acceptance reads *inside* `body`,
  /// where a retired scope never arrives.
  public func turn(named name: String, _ body: @escaping (Writer) -> Void) {
    guard let cogtext, !ownedScope.isRetired else { return }
    cogtext.turn(named: "\(namePath).\(name)", owner: ownedScope, body)
  }

  /// Reads a source without creating a dependency edge; see ``Cogs/peek(_:)-(Cog<Value>.Manual)``.
  ///
  /// An `operate`-time read never becomes a dependency, because `operate` is
  /// registration, not a reaction. Reading through a retired controller traps;
  /// see ``ifLive(_:)`` for the recoverable spelling.
  public func peek<Value>(_ valueReference: Cog<Value>.Manual) -> Value {
    requiredRuntime(for: "peek").peek(valueReference)
  }

  /// Reads an automatic cog without creating a dependency edge.
  public func peek<Value>(_ valueReference: Cog<Value>) -> Value {
    requiredRuntime(for: "peek").peek(valueReference)
  }

  /// Reads an async cog's current value without creating a dependency edge.
  public func peek<Value>(_ valueReference: Cog<Value>.Async) -> Value {
    requiredRuntime(for: "peek").peek(valueReference)
  }

  /// Reads a source's read-only projection without creating a dependency
  /// edge.
  public func peek<Value>(_ valueReference: Cog<Value>.Projection) -> Value {
    requiredRuntime(for: "peek").peek(valueReference)
  }

  /// Demands one fresh generation of an async value; see ``Cogs/refresh(_:)``.
  ///
  /// A retired controller cannot start demand, and the call traps rather than
  /// reporting a fabricated outcome. ``CogRefresh/Outcome/released`` means the
  /// owning state left the graph, which is a claim about shared state that one
  /// ended presentation is in no position to make. A handle obtained while this
  /// controller was live keeps its real exact-generation outcome; retirement
  /// never rewrites it.
  @discardableResult
  public func refresh<Value>(_ valueReference: Cog<Value>.Async) -> CogRefresh<Value> {
    requiredRuntime(for: "refresh").refresh(valueReference)
  }

}

// MARK: - Guarded access

extension MechanismController {
  /// Runs `body` only while this scope may still act, and returns `nil`
  /// otherwise.
  ///
  /// This is the recoverable spelling for the one case the inert primitives do
  /// not cover: work that finished despite cancellation and genuinely has to
  /// *read* before deciding what to do. Publication does not need it — a
  /// receipt-bearing op validates and reads inside its writer body, which a
  /// retired scope never reaches — but a completion that must consult state or
  /// ask for follow-up demand has nowhere else to put the check:
  ///
  /// ```swift
  /// let page = try await service.load(cursor)
  /// guard let m, m.ifLive({ $0.peek(isPresentedCog) }) == true else { return }
  /// await m.acceptPage(page, receipt: receipt)
  /// ```
  ///
  /// It reserves nothing. The check happens once, when the call begins; a turn
  /// opened inside `body` can retire this very scope, and the statements after
  /// it are then running through a retired controller. The primitive-level
  /// checks stay authoritative for exactly that reason — a `peek` after such a
  /// turn still traps. Keep the body to the read that motivated it.
  ///
  /// It is also not a cancellation handle and not a promise about the future:
  /// re-check after every suspension, because a check made before an `await`
  /// says nothing about the state of the world after it.
  ///
  /// - Parameter body: Synchronous graph work to perform only while live.
  /// - Returns: What `body` returned, or `nil` when this controller's scope has
  ///   been retired or its runtime is gone.
  @discardableResult
  public func ifLive<Result>(_ body: (MechanismController) -> Result) -> Result? {
    guard isLive else { return nil }
    return body(self)
  }
}
