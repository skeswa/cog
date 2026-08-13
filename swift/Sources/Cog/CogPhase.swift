/// The complete observable state of one asynchronous Cog value.
///
/// Async cogs have no observable initial phase. Their first read starts work
/// and returns ``pending(previous:)`` with ``Previous/none``. A reload keeps
/// the last successful value in `previous` while new work is pending or after
/// that work fails. A pending, success, or failure publication is a distinct
/// graph turn, so full-phase consumers can render transitions rather than only
/// the eventual value.
///
/// `CogPhase` is `nonisolated`, so its cases and accessors do not themselves
/// require the MainActor. Moving a phase across concurrency domains still
/// requires `Sendable`, which the type provides when `Value` is `Sendable`.
/// The contained failure uses existential `Error`, so consumers that need
/// domain-specific handling should cast or map it at their boundary.
public nonisolated enum CogPhase<Value> {
  /// Work is running, optionally alongside the last successful value.
  ///
  /// Initial work carries ``Previous/none``. Reloads continue to expose the
  /// most recent success even when intervening reloads failed.
  case pending(previous: Previous<Value>)

  /// The current generation completed successfully with `Value`.
  ///
  /// This value becomes the `previous` payload of later pending or failure
  /// phases until another generation succeeds or the state is released.
  case success(Value)

  /// The current generation failed, optionally retaining an earlier success.
  ///
  /// Cancellation caused by `.latest` replacement or lifetime release does
  /// not publish this case. A cancelled or otherwise stale generation is
  /// rejected even if its operation later throws or returns.
  case failure(any Error, previous: Previous<Value>)

  /// The last value work completed successfully, if one exists.
  ///
  /// Pending and failure return their retained success; success returns its
  /// value directly. This deliberately omits loading and error information and
  /// is the extraction used by an async cog's `latest` projection.
  ///
  /// When `Value` is itself optional, the outer optional reports whether any
  /// success exists and the inner optional is the successfully produced value.
  /// Thus no success and a successful `nil` remain distinct.
  public var latestValue: Value? {
    switch self {
    case .pending(let previous), .failure(_, let previous):
      switch previous {
      case .none:
        return nil
      case .some(let value):
        return value
      }
    case .success(let value):
      return value
    }
  }

  /// Whether the phase represents work currently in flight.
  ///
  /// This is `true` only for ``pending(previous:)``. A failure with a retained
  /// value and a success both return `false`.
  public var isLoading: Bool {
    if case .pending = self {
      return true
    }
    return false
  }
}

/// Whether an async state has a last successful value to retain.
///
/// This extra enum is intentional rather than a bare optional. When `Value`
/// itself is optional, ``none`` means work has never succeeded, while
/// ``some(_:)`` can contain a successful `nil`.
public nonisolated enum Previous<Value> {
  /// No generation of this state has completed successfully.
  case none

  /// A prior generation completed successfully with the associated value.
  case some(Value)
}

/// Phases may cross concurrency domains when their values may do so safely.
extension CogPhase: Sendable where Value: Sendable {}

/// Retained successes may cross concurrency domains with `Sendable` values.
extension Previous: Sendable where Value: Sendable {}

/// Retained-success presence and values compare structurally when possible.
extension Previous: Equatable where Value: Equatable {}
