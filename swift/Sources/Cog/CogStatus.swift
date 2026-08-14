/// The complete observable status of one asynchronous Cog value.
///
/// An async cog always has a total ``value``. Before its first accepted
/// success, that is the declaration's resting default. Pending and failure
/// statuses retain the latest accepted success when one exists, so request
/// chrome never forces a screen to discard useful content.
///
/// ``kind`` carries the request lifecycle without owning its associated data.
/// The neighboring ``value``, ``hasSucceeded``, ``error``, and ``isLoading``
/// fields remain total, independently readable projections of the same atomic
/// graph turn. At the SwiftUI boundary, Cog records Observation access in each
/// getter rather than when `cogs.status[valueReference]` creates this value.
/// A body therefore invalidates only when a status field it actually read
/// changes.
///
/// Obtaining a status through a read capability is still demand: the lens
/// settles the async state and starts initial work before returning this value.
/// Consumers interested only in equality-gated values should continue to use
/// the ordinary `c[valueReference]` or `cogs[valueReference]` spelling.
public nonisolated struct CogStatus<Value> {
  /// The lifecycle state of the current async generation.
  ///
  /// Associated data lives on the enclosing ``CogStatus`` so each field can be
  /// observed independently. Switching on `status.kind` observes lifecycle
  /// changes, while reading `status.value` or another field observes only that
  /// projection.
  public nonisolated enum Kind: Equatable, Sendable {
    /// Work is running.
    case pending

    /// The current generation completed successfully.
    case success

    /// The current generation failed.
    case failure
  }

  /// The lifecycle value without triggering Observation access.
  private let storedKind: Kind

  /// The renderable value without triggering Observation access.
  private let storedValue: Value

  /// The accepted-success flag without triggering Observation access.
  private let storedHasSucceeded: Bool

  /// The current failure without triggering Observation access.
  private let storedError: (any Error)?

  /// The optional field-level registrar attached only to UI status reads.
  ///
  /// Selector, reaction, watch, and peek snapshots leave this `nil`; their
  /// tracking semantics are established by the read operation itself. A
  /// SwiftUI status subscript attaches the async state's stable boundary so a
  /// copied status remains able to record whichever getters the body uses.
  private let observationBoundary: CogObservationBoundary?

  /// Whether work is pending, succeeded, or failed.
  public var kind: Kind {
    observationBoundary?.accessStatusKind()
    return storedKind
  }

  /// The value application code should render now.
  ///
  /// This field is total for every kind. It returns the latest accepted
  /// success, or the declaration's resting default before one exists.
  public var value: Value {
    observationBoundary?.accessStatusValue()
    return storedValue
  }

  /// Whether any generation has produced an accepted success.
  public var hasSucceeded: Bool {
    observationBoundary?.accessStatusHasSucceeded()
    return storedHasSucceeded
  }

  /// The current generation's error, or `nil` while loading or after success.
  public var error: (any Error)? {
    observationBoundary?.accessStatusError()
    return storedError
  }

  /// Whether work is currently in flight.
  public var isLoading: Bool {
    observationBoundary?.accessStatusIsLoading()
    return storedKind == .pending
  }

  /// Creates one unobserved runtime snapshot.
  ///
  /// Only Cog constructs statuses. Keeping construction internal prevents
  /// impossible combinations such as a successful kind with
  /// `hasSucceeded == false` or a pending kind carrying an error.
  private init(
    kind: Kind,
    value: Value,
    hasSucceeded: Bool,
    error: (any Error)?,
    observationBoundary: CogObservationBoundary? = nil
  ) {
    self.storedKind = kind
    self.storedValue = value
    self.storedHasSucceeded = hasSucceeded
    self.storedError = error
    self.observationBoundary = observationBoundary
  }

  /// Creates the honest pending status for a generation Cog has started.
  internal static func pending(value: Value, hasSucceeded: Bool) -> Self {
    Self(kind: .pending, value: value, hasSucceeded: hasSucceeded, error: nil)
  }

  /// Creates the status for one accepted successful generation.
  internal static func success(_ value: Value) -> Self {
    Self(kind: .success, value: value, hasSucceeded: true, error: nil)
  }

  /// Creates the status for one accepted failed generation.
  internal static func failure(
    _ error: any Error,
    value: Value,
    hasSucceeded: Bool
  ) -> Self {
    Self(kind: .failure, value: value, hasSucceeded: hasSucceeded, error: error)
  }

  /// Returns this atomic snapshot with field-level UI access recording attached.
  ///
  /// The stored status remains unobserved. Attaching the boundary only to the
  /// returned copy prevents selector, reaction, peek, and watch reads from
  /// accidentally registering Swift Observation dependencies.
  internal func observed(by boundary: CogObservationBoundary) -> Self {
    Self(
      kind: storedKind,
      value: storedValue,
      hasSucceeded: storedHasSucceeded,
      error: storedError,
      observationBoundary: boundary
    )
  }

  /// Determines which observable projections changed between two publications.
  ///
  /// `valuesAreEqual` is the declaration's same comparator used by the ordinary
  /// async value projection. Non-equatable declarations conservatively report
  /// every publication as a value change, preserving their existing behavior.
  @MainActor
  internal func observationChanges(
    from previous: Self?,
    valuesAreEqual: @MainActor (Value, Value) -> Bool
  ) -> CogStatusObservationFields {
    guard let previous else { return .all }

    var changes: CogStatusObservationFields = []
    if previous.storedKind != storedKind {
      changes.insert(.kind)
    }
    if !valuesAreEqual(previous.storedValue, storedValue) {
      changes.insert(.value)
    }
    if previous.storedHasSucceeded != storedHasSucceeded {
      changes.insert(.hasSucceeded)
    }
    // `any Error` has no equality contract. Two failure publications therefore
    // conservatively count as different errors, just as non-Equatable values do.
    if previous.storedError != nil || storedError != nil {
      changes.insert(.error)
    }
    if (previous.storedKind == .pending) != (storedKind == .pending) {
      changes.insert(.isLoading)
    }
    return changes
  }
}

/// Status snapshots may cross concurrency domains when their values may do so safely.
extension CogStatus: Sendable where Value: Sendable {}
