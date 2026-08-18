extension Cogs {
  /// Registers one reaction body under `label` and schedules its first tracking
  /// run.
  ///
  /// Application reactions remain a ``MechanismController`` capability, never
  /// public context API: reactions have one application-facing door, and it is
  /// a mechanism's controller (§6.3). ``CogValues`` reuses this internal
  /// tracked terminal to offer values; it exposes no arbitrary effect body.
  ///
  /// Shared by reactions and watches to preserve registration order and initial
  /// run scheduling. Registration owns the body, while the returned token owns
  /// the registration's terminal lifetime. During a flush, deferring the
  /// initial run prevents reentrant effects from observing a partially settled
  /// graph.
  internal func register(
    label: CogLabel,
    body: @escaping @MainActor (ReactionReader) -> Void
  ) -> ReactionToken {
    let reaction = CogReaction(cogs: self, label: label, body: body)
    reactions.append(reaction)
    if case .flushing = turnPhase {
      reactionRuns.append(.initial(reaction))
    } else {
      reaction.runInitially(in: self)
    }
    return ReactionToken(reaction: reaction)
  }

  /// Runs reachable changed reactions and deferred registrations in stable order.
  ///
  /// Changed registrations already present at flush start go first in original
  /// registration order. Initial runs requested earlier in the flush follow,
  /// and any registration created while this loop runs appends to the same
  /// tail. The index walk is deliberate: iterating a snapshot would lose those
  /// newly appended runs or force reentrancy.
  internal func flushReactions() {
    // Initial runs registered earlier in the flush wait behind every reaction
    // this turn already made reachable. Registrations made while this loop is
    // running append directly to the same tail.
    let deferredInitialRuns = reactionRuns
    reactionRuns.removeAll(keepingCapacity: true)

    for reaction in reactions where reaction.needsFlush(in: self) {
      reactionRuns.append(.changed(reaction))
    }
    reactionRuns.append(contentsOf: deferredInitialRuns)

    var index = 0
    while index < reactionRuns.count {
      let run = reactionRuns[index]
      index += 1
      run.perform(in: self)
    }

    reactionRuns.removeAll(keepingCapacity: true)
  }
}
