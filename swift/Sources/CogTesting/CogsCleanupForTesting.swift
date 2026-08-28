public import Cog

extension Cogs {
  /// Signals when this context's deinit cleanup reaches the MainActor.
  ///
  /// Tests that release their last context reference from another executor
  /// await the acknowledgement before asserting that mechanism registrations
  /// are gone and owned tasks received cancellation. The signal fires at the
  /// end of the context's isolated deinit, after every mechanism scope has
  /// been cancelled and graph dependency chains broken.
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
