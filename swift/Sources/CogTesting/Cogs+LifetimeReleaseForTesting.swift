public import Cog

// MARK: - Lifetime-release inspection

extension Cogs {
  /// Signals after the next eligible automatic root finishes graph removal.
  ///
  /// A lifetime test installs this before removing the last lease, advances its
  /// injected clock, then awaits the acknowledgement. The signal fires only
  /// after the root and its eligible dependency closure have been prepared and
  /// removed; a stale deadline or a state retained by a lease, UI boundary, or
  /// subscriber does not consume it.
  ///
  /// Only one release acknowledgement may be installed at a time, and it is
  /// consumed by one successful release.
  ///
  /// - Parameter acknowledgement: The one-shot MainActor signal completed
  ///   after removal finishes.
  public func acknowledgeNextAutomaticRelease(
    with acknowledgement: MainActorCleanupAcknowledgement
  ) {
    acknowledgeNextAutomaticRelease {
      acknowledgement.acknowledge()
    }
  }

  /// Signals after the next automatic grace-expiry eligibility check.
  ///
  /// Unlike ``acknowledgeNextAutomaticRelease(with:)``, this fires after the
  /// deadline reaches the MainActor even when identity, renewal, a lease, UI
  /// pinning, or a subscriber correctly prevents removal. Tests use it to
  /// establish that a negative release decision has completed without polling.
  /// Install at most one check acknowledgement at a time.
  ///
  /// - Parameter acknowledgement: The one-shot MainActor signal completed
  ///   after the next eligibility decision.
  public func acknowledgeNextAutomaticReleaseCheck(
    with acknowledgement: MainActorCleanupAcknowledgement
  ) {
    acknowledgeNextAutomaticReleaseCheck {
      acknowledgement.acknowledge()
    }
  }
}
