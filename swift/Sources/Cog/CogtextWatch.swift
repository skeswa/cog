extension Cogtext {
  /// Registers a reaction that watches one derived cog and receives its old and
  /// new values.
  ///
  /// A watch is an ordinary registration with a narrow shape: exactly one
  /// dependency, and a body handed values rather than a ``ReactionReader``.
  /// Everything a registration promises still holds — the context owns it in
  /// call order, only a real change wakes it, and its body runs inside the
  /// flush of the turn that changed the value, before the op that committed
  /// that turn returns.
  ///
  /// Installing always reads the cog, whichever start is asked for. That read
  /// is what subscribes the watch and what captures the old value the first
  /// change will hand back, so ``CogWatchStart/skip`` suppresses the call and
  /// not the read: a quiet install never costs a later wake-up.
  ///
  /// - Parameters:
  ///   - valueReference: The cog to watch.
  ///   - initial: Whether installing calls `body` once.
  ///   - name: What Cog should call this effect in debug history. Defaults to
  ///     the file and line of the registration.
  ///   - fileID: The registration's file for diagnostics. Leave this at its
  ///     default.
  ///   - line: The registration's line for diagnostics. Leave this at its
  ///     default.
  ///   - body: Synchronous effect code, given the value before this change and
  ///     the value after it.
  /// - Returns: A handle that keeps the registration alive. Releasing its last
  ///   reference cancels the watch.
  @discardableResult
  public func watch<Value>(
    _ valueReference: Cog<Value>,
    initial: CogWatchStart,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ body: @escaping @MainActor (Value, Value) -> Void
  ) -> ReactionToken {
    watchTracked(
      label: CogLabel(name: name, fileID: fileID, line: line),
      initial: initial,
      read: { c in c.get(valueReference) },
      body: body
    )
  }

  /// Registers a reaction that watches one source and receives its old and new
  /// values.
  ///
  /// The same watch the derived overload above documents, on a source.
  ///
  /// - Parameters:
  ///   - valueReference: The source to watch.
  ///   - initial: Whether installing calls `body` once.
  ///   - name: What Cog should call this effect in debug history. Defaults to
  ///     the file and line of the registration.
  ///   - fileID: The registration's file for diagnostics. Leave this at its
  ///     default.
  ///   - line: The registration's line for diagnostics. Leave this at its
  ///     default.
  ///   - body: Synchronous effect code, given the value before this change and
  ///     the value after it.
  /// - Returns: A handle that keeps the registration alive. Releasing its last
  ///   reference cancels the watch.
  @discardableResult
  public func watch<Value>(
    _ valueReference: ManualCog<Value>,
    initial: CogWatchStart,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ body: @escaping @MainActor (Value, Value) -> Void
  ) -> ReactionToken {
    watchTracked(
      label: CogLabel(name: name, fileID: fileID, line: line),
      initial: initial,
      read: { c in c.get(valueReference) },
      body: body
    )
  }

  /// Registers a watch on a source's read-only projection.
  ///
  /// A read-only value reference names the same one state its source does, so this is the
  /// source's watch under the value reference the rest of the app is allowed to hold.
  ///
  /// - Parameters:
  ///   - valueReference: The read-only value reference to watch.
  ///   - initial: Whether installing calls `body` once.
  ///   - name: What Cog should call this effect in debug history. Defaults to
  ///     the file and line of the registration.
  ///   - fileID: The registration's file for diagnostics. Leave this at its
  ///     default.
  ///   - line: The registration's line for diagnostics. Leave this at its
  ///     default.
  ///   - body: Synchronous effect code, given the value before this change and
  ///     the value after it.
  /// - Returns: A handle that keeps the registration alive. Releasing its last
  ///   reference cancels the watch.
  @discardableResult
  public func watch<Value>(
    _ valueReference: ReadOnlyCog<Value>,
    initial: CogWatchStart,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ body: @escaping @MainActor (Value, Value) -> Void
  ) -> ReactionToken {
    watchTracked(
      label: CogLabel(name: name, fileID: fileID, line: line),
      initial: initial,
      read: { c in c.get(valueReference) },
      body: body
    )
  }

  /// The one watch implementation, with the value-reference kind reduced to a read.
  ///
  /// The previously delivered value lives in this function's own `previous`
  /// local, captured by the reaction body. That is deliberate: a watch is
  /// generic over its value while ``CogReaction`` is not, and a captured local
  /// carries the type without introducing a generic class — which would owe an
  /// explicit `nonisolated deinit` to keep the release optimizer from crashing
  /// on a synthesized isolated one.
  ///
  /// The optional is storage presence, not value optionality. A watch on an
  /// optional value keeps "nothing delivered yet" distinct from "delivered
  /// nil", the same way ``ManualCogState`` keeps a staged nil distinct from no
  /// staged write at all.
  private func watchTracked<Value>(
    label: CogLabel,
    initial: CogWatchStart,
    read: @escaping @MainActor (ReactionReader) -> Value,
    body: @escaping @MainActor (Value, Value) -> Void
  ) -> ReactionToken {
    var previous: Value?

    return register(label: label) { c in
      // Read first, and unconditionally: this is the dependency edge, and on
      // the installing run it is also the baseline the first change reports
      // against.
      let current = read(c)
      let delivered = previous
      previous = current

      switch delivered {
      case .some(let old):
        body(old, current)
      case .none:
        // The installing run. An install has no transition, so `.run` reports
        // the current value as both halves and `.skip` reports nothing.
        if initial == .run {
          body(current, current)
        }
      }
    }
  }
}
