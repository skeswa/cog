/// Whether an async cog has produced a value, is loading one, or failed.
///
/// Async cogs have no observable initial phase. Their first read starts work
/// and returns ``pending(previous:)`` with ``Previous/none``. A reload keeps
/// the last successful value in `previous` while new work is pending or after
/// that work fails.
public nonisolated enum CogPhase<Value> {
  /// Work is running.
  case pending(previous: Previous<Value>)

  /// Work completed with a value.
  case success(Value)

  /// Work failed, optionally retaining the last successful value.
  case failure(any Error, previous: Previous<Value>)

  /// The last value work completed successfully, if one exists.
  ///
  /// When `Value` is itself optional, the outer optional reports whether a
  /// successful value exists and the inner optional is that value.
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

  /// Whether work is currently running for this value.
  public var isLoading: Bool {
    if case .pending = self {
      return true
    }
    return false
  }
}

/// A last successful async value, keeping absence distinct from an optional nil.
public nonisolated enum Previous<Value> {
  /// Work has never completed successfully.
  case none

  /// Work completed successfully with `Value`.
  case some(Value)
}

extension CogPhase: Sendable where Value: Sendable {}
extension Previous: Sendable where Value: Sendable {}
extension Previous: Equatable where Value: Equatable {}
