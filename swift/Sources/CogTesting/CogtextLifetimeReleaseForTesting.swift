public import Cog

extension Cogtext {
  /// Signals after the next derived state finishes grace expiry and graph removal.
  ///
  /// Lifetime tests install this before removing the last lease, advance their
  /// injected clock, and await the acknowledgement instead of yielding,
  /// polling, sleeping, or racing an unstructured cleanup task.
  public func acknowledgeNextDerivedRelease(
    with acknowledgement: MainActorCleanupAcknowledgement
  ) {
    acknowledgeNextDerivedRelease {
      acknowledgement.acknowledge()
    }
  }
}
