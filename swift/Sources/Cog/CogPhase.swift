/// The complete observable metadata for one asynchronous Cog value.
///
/// An async cog always has a total ``value``. Before its first accepted
/// success, that is the declaration's resting default. Pending and failure
/// metadata retain the latest accepted success when one exists, so request
/// chrome never forces a screen to discard useful content.
///
/// Reading metadata is demand: the first read starts work and returns
/// ``pending(value:hasSucceeded:)`` synchronously. Cog publishes every later
/// pending, success, and failure as a separate ordered graph turn. Consumers
/// interested only in equality-gated values should continue to use the ordinary
/// `c[valueReference]` spelling; consumers rendering request state use
/// `c.meta[valueReference]`.
///
/// `hasSucceeded` keeps an optional value honest. When `Value` is optional,
/// `value == nil` may mean either the resting default or an accepted successful
/// `nil`; the accompanying flag distinguishes those states without another
/// public wrapper type.
public nonisolated enum CogMeta<Value> {
  /// Work is running while the total value remains available.
  ///
  /// - Parameters:
  ///   - value: The last accepted success, or the declaration's resting default.
  ///   - hasSucceeded: Whether any generation has completed successfully.
  case pending(value: Value, hasSucceeded: Bool)

  /// The current generation completed successfully.
  ///
  /// - Parameter value: The value accepted from that generation.
  case success(Value)

  /// The current generation failed while the total value remains available.
  ///
  /// - Parameters:
  ///   - error: The error thrown by the accepted generation.
  ///   - value: The last accepted success, or the declaration's resting default.
  ///   - hasSucceeded: Whether any earlier generation completed successfully.
  case failure(any Error, value: Value, hasSucceeded: Bool)

  /// The value application code should render now.
  ///
  /// This accessor is total for every metadata case. It deliberately hides
  /// request uncertainty; use the neighboring flags or ``error`` when that
  /// uncertainty affects presentation.
  public var value: Value {
    switch self {
    case .pending(let value, _), .success(let value), .failure(_, let value, _):
      return value
    }
  }

  /// Whether any generation has produced an accepted success.
  public var hasSucceeded: Bool {
    switch self {
    case .pending(_, let hasSucceeded), .failure(_, _, let hasSucceeded):
      return hasSucceeded
    case .success:
      return true
    }
  }

  /// The current generation's error, or `nil` while loading or after success.
  public var error: (any Error)? {
    if case .failure(let error, _, _) = self {
      return error
    }
    return nil
  }

  /// Whether work is currently in flight.
  public var isLoading: Bool {
    if case .pending = self {
      return true
    }
    return false
  }
}

/// Metadata may cross concurrency domains when its value may do so safely.
extension CogMeta: Sendable where Value: Sendable {}
