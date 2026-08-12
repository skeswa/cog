public import Cog

extension Cogtext {
  /// Signals after the next derived state finishes grace expiry and graph removal.
  ///
  /// A lifetime test installs this before removing the last lease, advances its
  /// injected clock, then awaits the acknowledgement.
  public func acknowledgeNextDerivedRelease(
    with acknowledgement: MainActorCleanupAcknowledgement
  ) {
    acknowledgeNextDerivedRelease {
      acknowledgement.acknowledge()
    }
  }

  /// Signals after the next derived grace-expiry check, even when UI pinning
  /// correctly prevents removal.
  public func acknowledgeNextDerivedReleaseCheck(
    with acknowledgement: MainActorCleanupAcknowledgement
  ) {
    acknowledgeNextDerivedReleaseCheck {
      acknowledgement.acknowledge()
    }
  }
}
