/// The shared operation surface of the app runtime and a mechanism's
/// controller.
///
/// Define an op once in an `extension CogOps`. App code and views call it on
/// `Cogs`; a mechanism calls it on its controller. Both can write through the
/// same API without giving a mechanism the raw runtime (§3.2, §6.2).
///
/// ```swift
/// extension CogOps {
///   func selectCurrentLocation(_ zip: ZipCode) {
///     turn(_currentZipCog, to: zip)
///   }
/// }
/// ```
///
/// The protocol has only the op primitives: `turn`, non-tracking `peek`, async
/// `refresh`, and `discard`. It cannot register reactions or expose storage.
/// Only ``Cogs`` and ``MechanismController`` may conform.
@MainActor
public protocol CogOps {
  /// Opens one named turn and runs `body` against its staged writes.
  ///
  /// This is the primitive beneath every op. Call the defaulted
  /// ``turn(_:_:)`` sugar instead so the turn inherits the op's `#function`
  /// name; pass an explicit name only when the op's spelling is not the right
  /// history entry. A mechanism's controller composes its mechanism name onto
  /// the turn name, so history attributes the write to the mechanism that
  /// asked for it.
  ///
  /// - Parameters:
  ///   - name: The turn name recorded for diagnostics and history.
  ///   - body: The synchronous writes that make up the turn. The writer it
  ///     receives is valid only while that body is executing.
  func turn(named name: String, _ body: @escaping (Writer) -> Void)

  /// Reads a source's current value without creating a dependency edge.
  ///
  /// See ``Cogs/peek(_:)-(Cog<Value>.Manual)`` for the settlement and lifetime
  /// contract; both conformances share it exactly.
  func peek<Value>(_ valueReference: Cog<Value>.Manual) -> Value

  /// Reads an automatic cog's settled value without creating a dependency edge.
  func peek<Value>(_ valueReference: Cog<Value>) -> Value

  /// Reads an async cog's current value without creating a dependency edge.
  func peek<Value>(_ valueReference: Cog<Value>.Async) -> Value

  /// Reads a source's read-only projection without creating a dependency
  /// edge.
  func peek<Value>(_ valueReference: Cog<Value>.Projection) -> Value

  /// Demands one fresh generation of an async value.
  ///
  /// See ``Cogs/refresh(_:)`` for the demand, grace, and handle contract.
  @discardableResult
  func refresh<Value>(_ valueReference: Cog<Value>.Async) -> CogRefresh<Value>

  /// Releases one source state the application has finished with.
  ///
  /// This is the explicit half of Cog's lifetime model, and it exists for one
  /// gap. `whileObserved` releases state once the graph can see that nothing
  /// observes it — no reaction lease, no dependent subscription, no UI read.
  /// The UI half of that test is one-way: Swift Observation has no
  /// observer-removal hook, so a state a view body has read stays pinned for
  /// the life of the context (§5.3). That is correct for durable state and
  /// wrong for state keyed by a domain lifetime, where every presentation ID
  /// the app has ever shown keeps a row, a value, and a boundary.
  ///
  /// Call it when the domain lifetime ends, from the op that ends it:
  ///
  /// ```swift
  /// extension CogOps {
  ///   func closePresentation(_ id: PresentationID) {
  ///     turn { c in c[_openPresentationIDsCog].removeAll { $0 == id } }
  ///     discard(_presentationDraftCogs[id])
  ///   }
  /// }
  /// ```
  ///
  /// What it does, exactly:
  ///
  /// - Releases the exact descriptor-and-key state named, and the upstream
  ///   states that release disconnects, through the ordinary release cascade.
  /// - Detaches and then invalidates the state's Observation boundary, so a
  ///   view still reading it re-renders and reattaches instead of holding a
  ///   boundary that can never fire again. A later read recreates the state at
  ///   its declared starting value, exactly as an expired grace period would.
  /// - Runs at the first safe graph boundary as its own named turn: now when
  ///   the context is idle, otherwise after the open turn's flush in FIFO
  ///   order.
  ///
  /// What it deliberately does not do:
  ///
  /// - It does not reset anything. It releases one state, and only a
  ///   declaration that already says it may be released and start over —
  ///   `.whileObserved(resetToInitial: true)`, or an automatic cog's default —
  ///   is eligible. Discarding an `.app` source would lose a value that exists
  ///   nowhere else, so it fails in debug and release builds.
  /// - It does not take state away from another consumer. A state with a
  ///   durable lease or a live subscriber belongs to whoever holds it and is
  ///   left alone, to follow its ordinary release path when its real last owner
  ///   leaves. Removing one presentation cannot destroy state another
  ///   presentation is using.
  /// - It is not a feature reset and not a scope hook. Scope retirement issues
  ///   no discards; state ownership and registration ownership are separate
  ///   responsibilities, and the op that ends a lifetime states both.
  /// - It is not for async work. An async cog's generations belong to its
  ///   demand and lifetime rules; dropping one consumer must not cancel work
  ///   another still wants.
  ///
  /// A state that was never created is not an error: the call finds nothing and
  /// does nothing.
  ///
  /// - Parameter valueReference: The exact source state to release.
  func discard<Value>(_ valueReference: Cog<Value>.Manual)

  /// Releases one automatic cog's state, including its UI boundary.
  ///
  /// The same contract as the source overload. It is useful for a keyed
  /// automatic value derived per domain lifetime, which a UI read pins exactly
  /// as it pins a source. A discarded automatic cog recomputes from current
  /// dependencies at its next read.
  ///
  /// - Parameter valueReference: The exact automatic state to release.
  func discard<Value>(_ valueReference: Cog<Value>)
}

extension CogOps {
  /// Opens one turn named after the calling op and stages `body`'s writes.
  ///
  /// `turn` is the only write entry point. The writer overload groups
  /// related writes into one atomic turn; `#function` names the turn after
  /// the op that called it without extra code. Nested turns during the
  /// accumulating phase join the current turn; a turn requested while a
  /// turn is flushing waits in the FIFO queue as a later turn (§3.2).
  ///
  /// - Parameters:
  ///   - name: The turn name recorded for diagnostics and history. By
  ///     default, this is the op method that called `turn`.
  ///   - body: The synchronous writes that make up the turn. The writer it
  ///     receives is valid only while that body is executing.
  public func turn(_ name: String = #function, _ body: @escaping (Writer) -> Void) {
    turn(named: name, body)
  }

  /// Writes one value to one manual source in its own turn.
  ///
  /// This is the compact form for the common single-write operation. It keeps
  /// the writer form as Cog's sole multi-write boundary while avoiding a
  /// one-line writer closure at every domain setter.
  ///
  /// - Parameters:
  ///   - valueReference: The state-owned source to update.
  ///   - value: The value to publish at the turn boundary.
  ///   - name: The turn name recorded for diagnostics and history.
  public func turn<Value>(
    _ valueReference: Cog<Value>.Manual,
    to value: Value,
    name: String = #function
  ) {
    turn(named: name) { writer in
      writer[valueReference] = value
    }
  }
}

/// `Cogs` is the application-side op capability.
///
/// The requirements are implemented where each primitive lives: the turn
/// boundary beside ``Writer``, the peeks beside state storage, and refresh
/// beside async demand.
extension Cogs: CogOps {}
