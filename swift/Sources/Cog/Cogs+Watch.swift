// MARK: - Watches

/// The tracked-read machinery beneath every `MechanismController` watch.
///
/// Watches are MainActor-isolated registrations owned by the context and, at
/// the public surface, by a mechanism's scope. Installation captures one
/// baseline through ``ReactionReader``; later runs preserve normal reaction
/// ordering and execute only after the changed turn has settled. The public
/// overloads live on ``MechanismController``, because registration is a
/// controller capability (§6.3).
extension Cogs {
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
  internal func watchTracked<Value>(
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
