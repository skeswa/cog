extension Cogs {
  /// Registers a reaction and schedules its first tracking run.
  ///
  /// `run` is the general synchronous effect primitive. The body runs once to
  /// establish its initial dependency set, then reruns after completed turns
  /// only when a value read through its ``ReactionReader`` changed. Every run
  /// replaces the dependency set, so branches may change what triggers later
  /// work. `peek` reads remain one-shot and do not become dependencies.
  ///
  /// The context owns registrations in call order. A turn marks only reactions
  /// reachable from changed state; the flush then runs those reactions after
  /// their dependencies settle and leaves unrelated registrations quiet.
  /// Outside a flush the initial run completes before this method returns. A
  /// registration made during a flush joins that reaction queue's tail instead
  /// of re-entering its caller.
  ///
  /// Tracked reads of `whileObserved` derived or async roots acquire exact
  /// reaction-owned lifetime leases. Cancelling or releasing the returned token
  /// removes edges and leases; keep it alive for the entire effect lifetime.
  /// The context, registration, reader, and body are MainActor-isolated.
  ///
  /// - Parameters:
  ///   - fileID: The registration's file for diagnostics. Leave this at its
  ///     default.
  ///   - line: The registration's line for diagnostics. Leave this at its
  ///     default.
  ///   - body: Synchronous effect code. Read graph state through the supplied
  ///     ``ReactionReader``; call domain operations on the context to enqueue
  ///     writes rather than retaining the reader.
  /// - Returns: A handle that keeps the registration alive. Releasing its last
  ///   reference cancels the reaction.
  @discardableResult
  public func run(
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ body: @escaping @MainActor (ReactionReader) -> Void
  ) -> ReactionToken {
    register(label: CogLabel(name: nil, fileID: fileID, line: line), body: body)
  }

  /// Registers one reaction body under `label` and schedules its first tracking
  /// run.
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

    for reaction in reactions where reaction.settleState != .clean {
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
