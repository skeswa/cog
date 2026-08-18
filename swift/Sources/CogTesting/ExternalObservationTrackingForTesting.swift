public import Cog

/// External Observation runtime path selected for one isolated test context.
///
/// Production always follows availability automatically. This testing-only
/// selector makes the legacy one-shot behavior executable on newer CI hosts;
/// it is context-local and cannot change another runtime.
public nonisolated enum ExternalObservationTrackingForTesting: Sendable {
  /// Follow OS availability exactly as production does.
  case automatic

  /// Force the bounded pre-iOS-26 `withObservationTracking` re-arm path.
  case legacy
}

extension Cogs {
  /// Signals after the next legacy external-property observer has re-armed.
  ///
  /// Install this one-shot acknowledgement after the initial `c.track` read
  /// and before mutating the observed property. When ``wait()`` returns, the
  /// one-shot registration is live again and the same synchronous MainActor
  /// transition has published the newest post-setter value into Cog.
  ///
  /// The legacy API has an unavoidable disarmed window between its `willSet`
  /// callback and that re-arm. A mutation made inside the window is not covered
  /// by this signal and may be missed. Make the next mutation only after the
  /// acknowledgement when testing the supported guarantee.
  ///
  /// This method has no effect on continuous iOS 26 Observation. Use it only
  /// with a context created using `externalObservationTracking: .legacy`, and
  /// install at most one acknowledgement at a time.
  ///
  /// - Parameter acknowledgement: One-shot signal completed after the next
  ///   legacy re-arm transition.
  public func acknowledgeNextExternalObservationRearm(
    with acknowledgement: MainActorCleanupAcknowledgement
  ) {
    acknowledgeNextExternalObservationRearm {
      acknowledgement.acknowledge()
    }
  }
}
