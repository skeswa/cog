public import Cog

extension ReactionToken {
  /// Signals when this token's deinit cleanup reaches the MainActor.
  ///
  /// Tests that release their last token copy from another executor await the
  /// acknowledgement before asserting on the graph. Production code should
  /// call ``ReactionToken/cancel()`` when it needs an immediate stopping point.
  public func acknowledgeDeinitCleanup(
    with acknowledgement: MainActorCleanupAcknowledgement
  ) {
    acknowledgeDeinitCleanup {
      acknowledgement.acknowledge()
    }
  }
}
