extension Cogtext {
  /// Registers a reaction that watches one derived cog and receives its old and
  /// new values.
  ///
  /// A watch is a reaction with one dependency. Its body receives the old and
  /// new values. Changed watches run in registration order during the flush.
  ///
  /// Installation always reads the cog to subscribe and capture the baseline.
  /// ``CogWatchStart/skip`` suppresses only the initial body call.
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
      read: { c in c[valueReference] },
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
      read: { c in c[valueReference] },
      body: body
    )
  }

  /// Registers a watch on a source's read-only projection.
  ///
  /// The projection and source name the same state.
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
    _ valueReference: CogProjection<Value>,
    initial: CogWatchStart,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ body: @escaping @MainActor (Value, Value) -> Void
  ) -> ReactionToken {
    watchTracked(
      label: CogLabel(name: name, fileID: fileID, line: line),
      initial: initial,
      read: { c in c[valueReference] },
      body: body
    )
  }

  /// Implements every watch overload through one tracked read.
  ///
  /// The captured `previous` local carries the generic value type without a
  /// generic class, which would require the release-optimizer workaround.
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
      // This read records the dependency and captures the install baseline.
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
