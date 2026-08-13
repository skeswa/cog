public import Cog

extension Cogtext {
  /// Signals after the next async work completion reaches its generation check.
  ///
  /// The acknowledgement runs on the MainActor after one success or failure
  /// returns from its work task and Cog has checked whether that generation may
  /// still publish. It fires for an accepted completion and for a stale,
  /// cancelled, released, or dependency-invalidated completion that Cog drops.
  /// It does not alter settlement or install a graph consumer.
  ///
  /// This one-shot seam makes a negative public behavior deterministic. A test
  /// can resume controlled stale work, await the acknowledgement, and then
  /// inspect public phase state knowing no publication is still racing, without
  /// sleeps, polling, or access to the generation counter. Install at most one
  /// acknowledgement at a time.
  ///
  /// - Parameter acknowledgement: The signal to complete after the next result
  ///   eligibility check.
  public func acknowledgeNextAsyncCompletionCheck(
    with acknowledgement: MainActorCleanupAcknowledgement
  ) {
    acknowledgeNextAsyncCompletionCheck {
      acknowledgement.acknowledge()
    }
  }
}
