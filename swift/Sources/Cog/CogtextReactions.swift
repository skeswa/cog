extension Cogtext {
  /// Registers a reaction and schedules its first tracking run.
  ///
  /// The context owns registrations in call order. A turn marks only reactions
  /// reachable from changed state; the flush then runs those reactions after
  /// their dependencies settle and leaves unrelated registrations quiet.
  /// Outside a flush the initial run completes before this method returns. A
  /// registration made during a flush joins that reaction queue's tail instead
  /// of re-entering its caller.
  ///
  /// - Parameters:
  ///   - fileID: The registration's file for diagnostics. Leave this at its
  ///     default.
  ///   - line: The registration's line for diagnostics. Leave this at its
  ///     default.
  ///   - body: Synchronous effect code. Read graph state through the
  ///     ``ReactionReader`` it receives.
  /// - Returns: The stable handle for this registration.
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
  /// The one path every registration spelling takes to the graph, so that a
  /// watch and a plain reaction cannot drift apart on the two things a
  /// registration decides: where it lands in call order, and whether its first
  /// run happens now or joins the active flush's queue.
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

  /// Runs changed reactions at the end of a turn in registration order.
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
