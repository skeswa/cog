/// A runtime event `CogTesting` can await through a one-shot acknowledgement.
///
/// These events let a test await a decision that publishes no status, value,
/// or history entry. They cover rejected async results, grace checks, released
/// state closures, legacy Observation re-arms, and context teardown. Production
/// code never installs one. Each public `CogTesting` installer names one case.
///
/// One enum keeps install checks and consume-before-call ordering in one place.
/// Adding an event needs one case and one storage slot.
package enum CogRuntimeEvent {
  /// `isolated deinit` finished cancelling scopes and clearing the graph.
  ///
  /// Installation may replace the earlier callback. Teardown fires once, so a
  /// test is only moving its wait for that single event.
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
