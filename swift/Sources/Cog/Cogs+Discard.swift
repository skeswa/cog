// MARK: - Discarding state the application is finished with

/// Explicit release for state whose real owner is a domain lifetime.
///
/// Cog's ordinary lifetime rules answer "is anyone still using this?" from
/// evidence the graph can see: a reaction's lease, a dependent's subscription,
/// a UI read. That evidence is complete for everything except the UI, where
/// Swift Observation offers no observer-removal hook. A state a view body has
/// read therefore keeps its Observation boundary for the life of the context —
/// the pin recorded in §5.3 — because Cog cannot discover that the last view
/// reading it has gone.
///
/// For app-lifetime and long-lived state that is the right answer. For state
/// keyed by a domain lifetime it is not: a presentation ID that appeared once
/// leaves a row, a value, and a boundary behind forever, and a session's worth
/// of navigation accumulates them. Retiring the presentation's `scope` retires
/// its registrations, which is a different question with a different owner
/// (§6.2); nothing about ending an effect says the state is finished.
///
/// ``CogOps/discard(_:)-(Cog<Value>.Manual)`` supplies the one fact Cog cannot
/// observe: the application declaring that a keyed lifetime is over. It is
/// deliberately narrow. It names one exact state rather than a feature, it
/// works only on declarations that already say they may be released and start
/// over, and it never touches state another consumer still owns.
extension Cogs {
  /// Releases one exact state, including the UI boundary that pinned it.
  ///
  /// The work happens at the first safe graph boundary, as its own named turn:
  /// immediately when the context is idle, and otherwise after the open turn's
  /// flush, in FIFO order with every other deferred turn. Deferring is not
  /// politeness — releasing a row while its values are staged or its dependents
  /// are settling would tear the graph out from under active work.
  ///
  /// - Parameters:
  ///   - name: The turn name recorded for diagnostics and history.
  ///   - owner: The mechanism scope whose retirement rejects a deferred entry,
  ///     when a controller asked.
  ///   - identity: The exact descriptor-and-key state to release.
  internal func discardState(
    named name: String,
    owner: CogTurnOwner?,
    _ identity: CogStateIdentity
  ) {
    requireOutsideAutomaticComputation(forTurnNamed: name)
    withSystemTurn(name, owner: owner) { [weak self] _ in
      guard let self else { return }
      self.arenaCore.discardObservedState(identity)
    }
  }

  /// Releases one source state the application has finished with.
  ///
  /// See ``CogOps/discard(_:)-(Cog<Value>.Manual)`` for the contract; this
  /// conformance and a mechanism controller's share it exactly.
  public func discard<Value>(_ valueReference: Cog<Value>.Manual) {
    discardState(
      named: "discard",
      owner: nil,
      CogStateIdentity(
        descriptor: valueReference.descriptor.identity, key: valueReference.key)
    )
  }

  /// Releases one automatic cog's state, including its UI boundary.
  ///
  /// See ``CogOps/discard(_:)-(Cog<Value>)`` for the contract.
  public func discard<Value>(_ valueReference: Cog<Value>) {
    discardState(
      named: "discard",
      owner: nil,
      CogStateIdentity(
        descriptor: valueReference.descriptor.identity, key: valueReference.key)
    )
  }
}
