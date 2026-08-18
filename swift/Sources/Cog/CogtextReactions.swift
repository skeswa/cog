extension Cogs {
  /// Registers one effect body under `label` and schedules its first tracking run.
  ///
  /// Application reactions remain a ``MechanismController`` capability, never
  /// public context API: reactions have one application-facing door, and it is
  /// a mechanism's controller (§6.3).
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
    register(label: label, phase: .effect, body: body)
  }

  /// Registers one export offer body in the pre-effect flush phase.
  ///
  /// This is reserved for ``CogValues``. Keeping it separate from the ordinary
  /// registration capability makes changed value offers phase 4 work even when
  /// their iterator registered after a mechanism reaction.
  internal func registerExport(
    label: CogLabel,
    body: @escaping @MainActor (ReactionReader) -> Void
  ) -> ReactionToken {
    register(label: label, phase: .export, body: body)
  }

  /// Installs one phase-classified tracked terminal and schedules its first run.
  private func register(
    label: CogLabel,
    phase: CogReactionPhase,
    body: @escaping @MainActor (ReactionReader) -> Void
  ) -> ReactionToken {
    let reaction = CogReaction(cogs: self, label: label, phase: phase, body: body)
    switch phase {
    case .export:
      exportReactions.append(reaction)
    case .effect:
      reactions.append(reaction)
    }
    if case .flushing = turnPhase {
      reactionRuns.append(.initial(reaction))
    } else {
      reaction.runInitially(in: self)
    }
    return ReactionToken(reaction: reaction)
  }

  /// Runs reachable exports, then effects, in stable order within each phase.
  ///
  /// Changed exports are flush step 4, after UI notices and before effects.
  /// Changed registrations already present at flush start precede deferred
  /// initial runs inside their phase, and each group keeps registration order.
  /// A registration created while the indexed loop runs appends to the tail;
  /// iterating a snapshot would lose that run or force reentrancy.
  internal func flushReactions() {
    // Initial runs registered earlier in the flush wait behind changed runs in
    // their own phase. Registrations made while this loop runs append directly
    // to the same tail because their phase cannot retroactively precede a body
    // that is already executing.
    let deferredInitialRuns = reactionRuns
    reactionRuns.removeAll(keepingCapacity: true)

    for reaction in exportReactions where reaction.needsFlush(in: self) {
      reactionRuns.append(.changed(reaction))
    }
    for run in deferredInitialRuns where run.phase == .export {
      reactionRuns.append(run)
    }
    for reaction in reactions where reaction.needsFlush(in: self) {
      reactionRuns.append(.changed(reaction))
    }
    for run in deferredInitialRuns where run.phase == .effect {
      reactionRuns.append(run)
    }

    var index = 0
    while index < reactionRuns.count {
      let run = reactionRuns[index]
      index += 1
      run.perform(in: self)
    }

    reactionRuns.removeAll(keepingCapacity: true)
  }
}
