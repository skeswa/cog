/// A handle bound to one exact generation of asynchronous demand.
///
/// Awaiting ``outcome`` never drifts to a later request: replacement resolves
/// it as ``StorefrontRefreshOutcome/superseded`` and lifetime release resolves
/// it as ``StorefrontRefreshOutcome/released``. A resolved outcome is retained,
/// so awaiting after the runtime has long moved on is still safe and still
/// answers about the generation the handle names.
///
/// `Sendable` because a handle may be awaited from a task that is not the one
/// that created it; the value it carries is the runtime's, and the runtime
/// resolves it on the MainActor.
public protocol StorefrontRefreshHandle: Sendable {
  /// What this generation produced.
  ///
  /// `Sendable` because ``StorefrontRefreshOutcome`` carries it across an
  /// isolation boundary: the outcome is resolved on the MainActor and awaited
  /// from whatever task holds the handle.
  associatedtype Value: Sendable

  /// The terminal result of this exact generation.
  ///
  /// Resolves without a clock and without a poll. A generation that is replaced
  /// resolves at the moment of replacement, not when its task eventually
  /// finishes.
  var outcome: StorefrontRefreshOutcome<Value> { get async }
}

/// How one exact generation of asynchronous demand finished.
///
/// Mirrors Cog's `CogRefresh.Outcome` case for case, so the teardown phase's
/// checkpoint compares one word across four runtimes.
public nonisolated enum StorefrontRefreshOutcome<Value>: Sendable where Value: Sendable {
  /// The runtime accepted and published this generation's value.
  case success(Value)
  /// The runtime accepted and published this generation's error.
  case failure(any Error)
  /// Newer work, or an invalidated selection, made this generation stale
  /// before it could publish.
  case superseded
  /// The owning value left the runtime before this generation completed.
  case released

  /// The single word a checkpoint compares.
  ///
  /// Deliberately not `CustomStringConvertible`: a checkpoint must compare the
  /// case, never a payload, so that four runtimes producing four different
  /// recommendation lists still agree that the demand was superseded.
  public var checkpointDescription: String {
    switch self {
    case .success: "success"
    case .failure: "failure"
    case .superseded: "superseded"
    case .released: "released"
    }
  }
}
