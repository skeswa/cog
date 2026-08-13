/// The complete observable state of one asynchronous Cog value.
///
/// Async cogs have no observable initial phase. Their first read starts work,
/// establishes ``pending(previous:)`` with ``Previous/none``, and returns it
/// synchronously. Cog records that transition as a graph-owned pending turn;
/// when the read occurs during selector or reaction evaluation, its flush waits
/// until evaluation exits so it cannot reenter the active consumer. A reload
/// keeps the last successful value in `previous` while new work is pending or
/// after that work fails. Pending, success, and failure remain separately
/// ordered phase transitions, so full-phase consumers can render the process
/// rather than only the eventual value.
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
  ///
  /// - Parameter previous: Presence and value of the last accepted success.
  case pending(previous: Previous<Value>)

  /// The current generation completed successfully with `Value`.
  ///
  /// This value becomes the `previous` payload of later pending or failure
  /// phases until another generation succeeds or the state is released.
  ///
  /// - Parameter value: The value accepted from the current generation.
  case success(Value)

  /// The current generation failed, optionally retaining an earlier success.
  ///
  /// Cancellation caused by `.latest` replacement or lifetime release does
  /// not publish this case. A cancelled or otherwise stale generation is
  /// rejected even if its operation later throws or returns.
  ///
  /// - Parameters:
  ///   - error: The error thrown by the current accepted generation.
  ///   - previous: Presence and value of the last accepted success.
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
  ///
  /// - Returns: The current or retained successful value, or `nil` when no
  ///   generation has succeeded.
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
  ///
  /// - Returns: Whether this phase represents an in-flight generation.
  public var isLoading: Bool {
    if case .pending = self {
      return true
    }
    return false
  }

  /// The successful value of the current generation, if that is how it ended.
  ///
  /// Unlike ``latestValue``, this never surfaces a retained previous success:
  /// pending and failure return `nil` whatever their `previous` carries. It
  /// answers "did the current generation succeed," where `latestValue`
  /// answers "what should be on screen."
  ///
  /// When `Value` is itself optional, the outer optional reports whether the
  /// current generation succeeded and the inner optional is the value it
  /// produced, so a successful `nil` remains distinct from pending and
  /// failure — the same nesting rule as `latestValue`.
  ///
  /// - Returns: The current generation's successful value, or `nil` for
  ///   pending and failure phases.
  public var value: Value? {
    if case .success(let value) = self {
      return value
    }
    return nil
  }

  /// The error of the current generation, if that is how it ended.
  ///
  /// Pending and success return `nil`, including a reload retrying after an
  /// earlier failure: the error belonged to the generation that published it,
  /// and its replacement publicly begins at pending again. The error keeps
  /// its existential type; consumers that need domain-specific handling cast
  /// or map it at their boundary.
  ///
  /// - Returns: The current generation's error, or `nil` for pending and
  ///   success phases.
  public var error: (any Error)? {
    if case .failure(let error, _) = self {
      return error
    }
    return nil
  }

  /// Whether this is a first load, with no retained success to show.
  ///
  /// This is `true` only for ``pending(previous:)`` carrying
  /// ``Previous/none``. Together with ``isReloading`` it splits ``isLoading``
  /// by retained success, so a consumer can show a skeleton for a first load
  /// and keep the last good value on screen for a reload without matching
  /// through `Previous`.
  ///
  /// - Returns: Whether in-flight work has no retained success to fall back
  ///   on.
  public var isInitialLoading: Bool {
    if case .pending(previous: .none) = self {
      return true
    }
    return false
  }

  /// Whether this is a reload, still holding the last accepted success.
  ///
  /// This is `true` only for ``pending(previous:)`` carrying
  /// ``Previous/some(_:)``, including a retained successful `nil` for
  /// optional values. Failure phases return `false` even when they retain a
  /// previous success: they represent finished work, not a reload in flight.
  ///
  /// - Returns: Whether in-flight work retains the last accepted success.
  public var isReloading: Bool {
    if case .pending(previous: .some(_)) = self {
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
  ///
  /// - Parameter value: The last accepted success, including `nil` when
  ///   `Value` is optional.
  case some(Value)
}

/// Phases may cross concurrency domains when their values may do so safely.
extension CogPhase: Sendable where Value: Sendable {}

/// Retained successes may cross concurrency domains with `Sendable` values.
extension Previous: Sendable where Value: Sendable {}

/// Retained-success presence and values compare structurally when possible.
extension Previous: Equatable where Value: Equatable {}
