public import Cog

extension Cogtext {
  /// Signals after the next async work completion reaches its generation check.
  ///
  /// Tests use this when a stale result must produce no public event: resume
  /// the controlled work, await the acknowledgement, then inspect public state.
  public func acknowledgeNextAsyncCompletionCheck(
    with acknowledgement: MainActorCleanupAcknowledgement
  ) {
    acknowledgeNextAsyncCompletionCheck {
      acknowledgement.acknowledge()
    }
  }
}
