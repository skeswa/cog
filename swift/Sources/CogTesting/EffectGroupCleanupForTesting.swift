public import Cog

extension EffectGroup {
  /// Signals when this group's deinit cleanup reaches the MainActor.
  ///
  /// Tests that release their last group copy from another executor await the
  /// acknowledgement before asserting on the graph and owned tasks. Production
  /// code should call ``EffectGroup/cancel()`` when it needs an immediate
  /// stopping point.
  ///
  /// - Parameter acknowledgement: The one-shot signal completed after graph
  ///   and task cleanup finishes on the MainActor.
  public func acknowledgeDeinitCleanup(
    with acknowledgement: MainActorCleanupAcknowledgement
  ) {
    acknowledgeDeinitCleanup {
      acknowledgement.acknowledge()
    }
  }
}
