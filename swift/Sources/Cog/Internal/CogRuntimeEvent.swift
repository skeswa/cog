/// A runtime event `CogTesting` can await through a one-shot acknowledgement.
///
/// These are the runtime's deterministic negative-event signals: moments a
/// test must await that produce no public status, value, or history event —
/// a rejected async result, a grace-expiry check, a released state closure, a
/// legacy Observation re-arm, or context teardown itself. Production code
/// never installs an acknowledgement; the `CogTesting` product's public
/// functions are the only installers, and each names exactly one case here.
///
/// One enum rather than one stored callback per event keeps the install and
/// consume protocol in a single place: one installer owns the double-install
/// trap, one firer owns consume-then-call ordering, and adding an event is a
/// new case plus a storage slot rather than a third parallel method family.
package enum CogRuntimeEvent {
  /// `isolated deinit` finished cancelling scopes and clearing the graph.
  ///
  /// Unlike every other event, installation may replace an earlier callback:
  /// teardown fires at most once per context, so "next" and "only" coincide
  /// and re-installation is a test rearranging its own wait, not a conflict.
  case deinitCleanup

  /// An eligible automatic-state closure was actually removed.
  case lifetimeRelease

  /// A grace-expiry eligibility check finished, whether or not it released.
  case lifetimeReleaseCheck

  /// An async result reached its generation and state-identity decision,
  /// accepted or rejected.
  case asyncCompletionCheck

  /// The legacy external-observation bridge installed its next one-shot
  /// registration and published the post-change value.
  case externalObservationRearm

  /// How the double-install trap names this event.
  package var diagnosticName: String {
    switch self {
    case .deinitCleanup: "deinit cleanup"
    case .lifetimeRelease: "automatic release"
    case .lifetimeReleaseCheck: "release check"
    case .asyncCompletionCheck: "async completion check"
    case .externalObservationRearm: "Observation re-arm"
    }
  }
}

/// Fixed storage for at most one acknowledgement per runtime event.
///
/// A struct of optionals rather than a dictionary: the firers sit on paths
/// that run per async completion and per grace check, where consuming an
/// absent callback must stay a plain optional load with no hashing or
/// allocation. The subscript is the one place a case maps to its slot.
internal struct CogRuntimeAcknowledgements {
  /// One optional slot per ``CogRuntimeEvent`` case.
  private var deinitCleanup: (@MainActor @Sendable () -> Void)?
  private var lifetimeRelease: (@MainActor @Sendable () -> Void)?
  private var lifetimeReleaseCheck: (@MainActor @Sendable () -> Void)?
  private var asyncCompletionCheck: (@MainActor @Sendable () -> Void)?
  private var externalObservationRearm: (@MainActor @Sendable () -> Void)?

  /// The stored acknowledgement for one event, if a test installed one.
  internal subscript(event: CogRuntimeEvent) -> (@MainActor @Sendable () -> Void)? {
    get {
      switch event {
      case .deinitCleanup: deinitCleanup
      case .lifetimeRelease: lifetimeRelease
      case .lifetimeReleaseCheck: lifetimeReleaseCheck
      case .asyncCompletionCheck: asyncCompletionCheck
      case .externalObservationRearm: externalObservationRearm
      }
    }
    set {
      switch event {
      case .deinitCleanup: deinitCleanup = newValue
      case .lifetimeRelease: lifetimeRelease = newValue
      case .lifetimeReleaseCheck: lifetimeReleaseCheck = newValue
      case .asyncCompletionCheck: asyncCompletionCheck = newValue
      case .externalObservationRearm: externalObservationRearm = newValue
      }
    }
  }
}
