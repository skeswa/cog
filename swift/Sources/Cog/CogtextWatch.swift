/// Adds single-value reactions that report old and new values.
///
/// Watches are MainActor-isolated registrations owned by their ``Cogtext`` and
/// kept active by the returned ``ReactionToken``. Installation captures one
/// baseline through ``ReactionReader``; later runs preserve normal reaction
/// ordering and execute only after the changed turn has settled.
extension Cogtext {
  /// Registers a reaction that watches an async cog's full phase.
  ///
  /// Installation settles the exact async state, records it as the watch's one
  /// tracked dependency, and captures that phase as the baseline. A first read
  /// can start work, so the baseline is normally
  /// ``CogPhase/pending(previous:)``. ``CogWatchStart/skip`` suppresses only the
  /// initial body call; it does not skip the read or subscription. If that cold
  /// read establishes pending while the reaction is tracking, Cog defers the
  /// graph-owned pending flush until installation exits rather than reentering
  /// the watch.
  ///
  /// Pending, success, and failure are published in separate turns. After each
  /// such turn settles, the watch runs in registration order and receives its
  /// previous and current phases. Because it is a durable reaction consumer,
  /// the returned token holds a `whileObserved` lease on the async state. The
  /// last token release cancels the watch and begins ordinary grace when no
  /// other durable consumer remains.
  ///
  /// - Parameters:
  ///   - valueReference: The async value whose full phase should be watched.
  ///   - initial: Whether installation calls `body` with the baseline phase as
  ///     both arguments.
  ///   - name: What Cog should call this effect in debug history. Defaults to
  ///     the file and line of the registration.
  ///   - fileID: The registration's file for diagnostics. Leave this at its
  ///     default.
  ///   - line: The registration's line for diagnostics. Leave this at its
  ///     default.
  ///   - body: Synchronous effect code, given the phase before this change and
  ///     the phase after it. The body runs on the MainActor; commits it requests
  ///     during a flush become later FIFO turns.
  /// - Returns: A handle that keeps the registration and its async-state lease
  ///   alive. Releasing its last reference cancels the watch.
  @discardableResult
  public func watch<Value>(
    _ valueReference: AsyncCog<Value>,
    initial: CogWatchStart,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ body: @escaping @MainActor (CogPhase<Value>, CogPhase<Value>) -> Void
  ) -> ReactionToken {
    watchTracked(
      label: CogLabel(name: name, fileID: fileID, line: line),
      initial: initial,
      read: { c in c[valueReference] },
      body: body
    )
  }

  /// Registers a reaction that watches one derived cog and receives its old and
  /// new values.
  ///
  /// Installation settles the exact descriptor-and-key state, records it as the
  /// watch's dependency, and captures the returned value as the baseline.
  /// ``CogWatchStart/skip`` suppresses only the initial body call; it does not
  /// skip settlement or subscription. Outside a flush installation completes
  /// synchronously. Installation requested during a flush joins that flush's
  /// reaction queue instead of reentering its caller.
  ///
  /// Later changed turns run watches in registration order after dependencies
  /// settle. An equality-gated cog keeps the watch quiet when recomputation is
  /// equal. The token owns the registration and its `whileObserved` lease on the
  /// exact derived state; releasing its last reference cancels both and may
  /// begin grace.
  ///
  /// - Parameters:
  ///   - valueReference: The cog to watch.
  ///   - initial: Whether installation calls `body` once with the baseline as
  ///     both old and new values.
  ///   - name: What Cog should call this effect in debug history. Defaults to
  ///     the file and line of the registration.
  ///   - fileID: The registration's file for diagnostics. Leave this at its
  ///     default.
  ///   - line: The registration's line for diagnostics. Leave this at its
  ///     default.
  ///   - body: Synchronous effect code, given the value before this change and
  ///     the value after it. The body runs on the MainActor; commits it requests
  ///     during a flush become later FIFO turns.
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
  /// Installation reads the source from the latest completed turn and records
  /// its exact descriptor-and-key state as the dependency. `initial` controls
  /// only delivery of that baseline; subscription always occurs. Later changed
  /// source turns run watches in registration order after mutation has closed.
  /// Manual state has context lifetime, so cancelling the returned token removes
  /// the reaction but does not release or reset the source.
  ///
  /// - Parameters:
  ///   - valueReference: The source to watch.
  ///   - initial: Whether installation calls `body` once with the baseline as
  ///     both old and new values.
  ///   - name: What Cog should call this effect in debug history. Defaults to
  ///     the file and line of the registration.
  ///   - fileID: The registration's file for diagnostics. Leave this at its
  ///     default.
  ///   - line: The registration's line for diagnostics. Leave this at its
  ///     default.
  ///   - body: Synchronous effect code, given the value before this change and
  ///     the value after it. The body runs on the MainActor; commits it requests
  ///     during a flush become later FIFO turns.
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
  /// The projection and source name the same state, so installation, ordering,
  /// baseline delivery, and cancellation match the source overload. This
  /// spelling exposes no write capability to the registration site.
  ///
  /// - Parameters:
  ///   - valueReference: The read-only value reference to watch.
  ///   - initial: Whether installation calls `body` once with the baseline as
  ///     both old and new values.
  ///   - name: What Cog should call this effect in debug history. Defaults to
  ///     the file and line of the registration.
  ///   - fileID: The registration's file for diagnostics. Leave this at its
  ///     default.
  ///   - line: The registration's line for diagnostics. Leave this at its
  ///     default.
  ///   - body: Synchronous effect code, given the value before this change and
  ///     the value after it. The body runs on the MainActor; commits it requests
  ///     during a flush become later FIFO turns.
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
  ///
  /// Reading precedes delivery so the reaction's dependency and lease set are
  /// reconciled before any queued graph-owned turn can flush. In particular, a
  /// cold async dependency may establish pending during the read, but its turn
  /// waits until reaction tracking has completed.
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
