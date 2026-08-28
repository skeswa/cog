public import Cog

extension Cogs {
  /// Signals when this context's deinit cleanup reaches the MainActor.
  ///
  /// A test that drops its last context reference on another executor can await
  /// this signal before checking cleanup. It fires after isolated deinit has
  /// cancelled mechanism scopes and broken graph dependency chains.
  ///
  /// - Parameter acknowledgement: The one-shot signal completed after
  ///   teardown finishes on the MainActor.
  public func acknowledgeDeinitCleanup(
    with acknowledgement: MainActorCleanupAcknowledgement
  ) {
    acknowledgeNext(.deinitCleanup) {
      acknowledgement.acknowledge()
    }
  }
}
