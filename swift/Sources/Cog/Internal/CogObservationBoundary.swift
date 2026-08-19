import Observation

/// The Observation boundary for one UI-read Cog state.
///
/// A normal value uses the `value` phantom property. An async status uses one
/// phantom property per public field so a SwiftUI body reading retained content
/// does not also subscribe to loading or error changes. Phantom values are
/// irrelevant; their key paths connect a field read to its later change notice.
/// States that never reach the UI never allocate this object.
/// The state owns the boundary, and the context's ordered boundary list retains
/// that state for the rest of the context lifetime; this permanent pin is the UI
/// lifetime lease for a `.whileObserved` state.
internal nonisolated final class CogObservationBoundary: Observable, @unchecked Sendable {
  private let registrar = ObservationRegistrar()
  #if DEBUG
  @MainActor private var hasDeferredChange = false
  #endif

  /// The key path used by manual and derived value reads.
  private var value: Bool { false }

  /// The key path used by ``CogStatus/kind`` reads.
  private var statusKind: Bool { false }

  /// The key path used by ``CogStatus/value`` reads.
  private var statusValue: Bool { false }

  /// The key path used by ``CogStatus/hasSucceeded`` reads.
  private var statusHasSucceeded: Bool { false }

  /// The key path used by ``CogStatus/error`` reads.
  private var statusError: Bool { false }

  /// The key path used by ``CogStatus/isLoading`` reads.
  private var statusIsLoading: Bool { false }

  /// Registers a read in the caller's active Observation tracking scope.
  ///
  /// Registration and the corresponding state read are one synchronous
  /// MainActor operation, so no turn can publish between them. A synchronous
  /// derived subscript registers before its pull; the async subscript settles
  /// first so initial pending can be installed without invalidating that new
  /// Observation baseline.
  func accessValue() {
    registrar.access(self, keyPath: \.value)
  }

  /// Registers a `CogStatus.kind` read in the active tracking scope.
  func accessStatusKind() {
    registrar.access(self, keyPath: \.statusKind)
  }

  /// Registers a `CogStatus.value` read in the active tracking scope.
  func accessStatusValue() {
    registrar.access(self, keyPath: \.statusValue)
  }

  /// Registers a `CogStatus.hasSucceeded` read in the active tracking scope.
  func accessStatusHasSucceeded() {
    registrar.access(self, keyPath: \.statusHasSucceeded)
  }

  /// Registers a `CogStatus.error` read in the active tracking scope.
  func accessStatusError() {
    registrar.access(self, keyPath: \.statusError)
  }

  /// Registers a `CogStatus.isLoading` read in the active tracking scope.
  func accessStatusIsLoading() {
    registrar.access(self, keyPath: \.statusIsLoading)
  }

  /// Invalidates an active reader after the state really changed.
  ///
  /// The context calls this after all pending sources have published and the UI
  /// root has settled, but before reactions run for the same completed revision.
  @MainActor
  func notifyValueChange() {
    registrar.withMutation(of: self, keyPath: \.value) {}
  }

  /// Invalidates only status fields whose values changed in this graph turn.
  @MainActor
  func notifyStatusChanges(_ fields: CogStatusObservationFields) {
    if fields.contains(.kind) {
      registrar.withMutation(of: self, keyPath: \.statusKind) {}
    }
    if fields.contains(.value) {
      registrar.withMutation(of: self, keyPath: \.statusValue) {}
    }
    if fields.contains(.hasSucceeded) {
      registrar.withMutation(of: self, keyPath: \.statusHasSucceeded) {}
    }
    if fields.contains(.error) {
      registrar.withMutation(of: self, keyPath: \.statusError) {}
    }
    if fields.contains(.isLoading) {
      registrar.withMutation(of: self, keyPath: \.statusIsLoading) {}
    }
  }

  #if DEBUG
  /// Remembers a quiet debug seed until the next real turn can notify it.
  @MainActor
  func deferChange() {
    hasDeferredChange = true
  }

  /// Consumes the seed change assigned to the next real turn, if any.
  @MainActor
  func consumeDeferredChange() -> Bool {
    defer { hasDeferredChange = false }
    return hasDeferredChange
  }
  #endif
}

/// State that may acquire a lazy UI observation boundary.
///
/// `observationBoundary == nil` means no UI read has ever pinned this exact
/// descriptor-and-key state. Boundaries are never removed or transferred.
@MainActor
internal protocol CogObservationState: CogState {
  /// The permanent UI boundary after first access, or `nil` before any UI read.
  var observationBoundary: CogObservationBoundary? { get set }
  /// The erased state key included in debug notice history.
  var observationKey: CogKey? { get }
  /// Sends the field-appropriate Observation mutations for this state's change.
  func notifyObservationChange()
}

extension CogObservationState {
  /// Gets or creates this state's boundary without choosing an observed field.
  ///
  /// Creation permanently pins the state in deterministic boundary-flush
  /// order. The caller records either an ordinary value read or a particular
  /// async status field after this method returns.
  @discardableResult
  func ensureObservationBoundary(in cogs: Cogs) -> CogObservationBoundary {
    let boundary: CogObservationBoundary
    if let existing = observationBoundary {
      boundary = existing
    } else {
      boundary = CogObservationBoundary()
      observationBoundary = boundary
      cogs.registerObservationState(self)
    }

    return boundary
  }

  /// Records one ordinary value read through this state's stable boundary.
  @discardableResult
  func accessObservationBoundary(in cogs: Cogs) -> CogObservationBoundary {
    let boundary = ensureObservationBoundary(in: cogs)
    boundary.accessValue()
    return boundary
  }

  /// Sends the normal single-value mutation for manual and derived states.
  func notifyObservationChange() {
    observationBoundary?.notifyValueChange()
  }
}

/// The independently observable fields of one ``CogStatus`` publication.
internal nonisolated struct CogStatusObservationFields: OptionSet, Sendable {
  /// The compact bitset representation used only inside the Observation boundary.
  let rawValue: UInt8

  /// The lifecycle kind changed.
  static let kind = Self(rawValue: 1 << 0)

  /// The total renderable value changed under the declaration's equality rule.
  static let value = Self(rawValue: 1 << 1)

  /// Whether any generation has succeeded changed.
  static let hasSucceeded = Self(rawValue: 1 << 2)

  /// The presence of a current error changed.
  static let error = Self(rawValue: 1 << 3)

  /// Whether work is in flight changed.
  static let isLoading = Self(rawValue: 1 << 4)

  /// Every public status field, used only before a previous snapshot exists.
  static let all: Self = [.kind, .value, .hasSucceeded, .error, .isLoading]
}

extension Cogs {
  /// Settles UI-read roots and notifies only values changed in this revision.
  ///
  /// Snapshot the count before settlement because a selector may lazily create
  /// another boundary while it runs. Such a boundary has established its own
  /// current baseline and joins the next flush; notifying it in the same pass
  /// could report a change predating its first observed value.
  internal func flushObservationBoundaries() {
    #if COG_CORE_ARENA
    arenaCore.flushObservationBoundaries(in: self)
    #else
    flushClassObservationBoundaries()
    #endif
  }

  /// Flushes the simple core's class-backed UI roots.
  ///
  /// Manual, synchronous derived, and async states all use this path when the
  /// correctness core is selected. The arena build compiles the call out and
  /// flushes its descriptor-dispatched scalar roots instead.
  private func flushClassObservationBoundaries() {
    let boundaryCount = observationStates.count
    for state in observationStates.prefix(boundaryCount) {
      if state.settleState != .clean,
        let derived = state.asDerivedSettleState
      {
        settle(derived)
      }

      let changedThisTurn = state.changedAt == revision
      #if DEBUG
      let changedBySeed = state.observationBoundary?.consumeDeferredChange() ?? false
      guard changedThisTurn || changedBySeed else { continue }
      recordHistoryNotice(label: state.label, key: state.observationKey)
      #else
      guard changedThisTurn else { continue }
      #endif
      if changedThisTurn {
        state.notifyObservationChange()
      } else {
        state.observationBoundary?.notifyValueChange()
      }
    }
  }
}
