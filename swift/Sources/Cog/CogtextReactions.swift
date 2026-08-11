extension Cogtext {
  /// Registers a reaction and performs its first tracking run before returning.
  ///
  /// The context owns registrations in call order. A turn marks only reactions
  /// reachable from changed state; the flush then runs those reactions after
  /// their dependencies settle and leaves unrelated registrations quiet.
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
    let reaction = CogReaction(
      label: CogLabel(name: nil, fileID: fileID, line: line),
      body: body
    )
    reactions.append(reaction)
    reaction.runInitially(in: self)
    return ReactionToken(reaction: reaction)
  }

  /// Runs changed reactions at the end of a turn in registration order.
  internal func flushReactions() {
    for reaction in reactions {
      reaction.runIfNeeded(in: self)
    }
  }
}
