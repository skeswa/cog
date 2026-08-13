import Observation

/// The Observation boundary for one UI-read Cog state.
///
/// Every boundary exposes the same phantom property. Its value is irrelevant;
/// the registrar uses its key path to connect a view read to a later changed
/// value notice. States that never reach the UI never allocate this object.
/// The state owns the boundary, and the context's ordered boundary list retains
/// that state for the rest of the context lifetime; this permanent pin is the UI
/// lifetime lease for a `.whileObserved` state.
@MainActor
internal final class CogObservationBoundary: Observable {
  private let registrar = ObservationRegistrar()
  #if DEBUG
  private var hasDeferredChange = false
  #endif

  /// The one key path every boundary reports to Observation.
  private var value: Bool { false }

  /// Registers a read in the caller's active Observation tracking scope.
  ///
  /// Registration and the corresponding state read are one synchronous
  /// MainActor operation, so no turn can publish between them. A synchronous
  /// derived subscript registers before its pull; the async subscript settles
  /// first so initial pending can be installed without invalidating that new
  /// Observation baseline.
  func access() {
    registrar.access(self, keyPath: \.value)
  }

  /// Invalidates an active reader after the state really changed.
  ///
  /// The context calls this after all pending sources have published and the UI
  /// root has settled, but before reactions run for the same completed revision.
  func notifyChange() {
    registrar.withMutation(of: self, keyPath: \.value) {}
  }

  #if DEBUG
  /// Remembers a quiet debug seed until the next real turn can notify it.
  func deferChange() {
    hasDeferredChange = true
  }

  /// Consumes the seed change assigned to the next real turn, if any.
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
  var observationKey: AnyHashable? { get }
}

extension CogObservationState {
  /// Gets or creates this state's boundary and records one UI read.
  ///
  /// Registration happens before `access()`: a first access therefore both
  /// cancels any grace deadline through context registration and enters the
  /// state into deterministic boundary-flush order.
  @discardableResult
  func accessObservationBoundary(in cogs: Cogtext) -> CogObservationBoundary {
    let boundary: CogObservationBoundary
    if let existing = observationBoundary {
      boundary = existing
    } else {
      boundary = CogObservationBoundary()
      observationBoundary = boundary
      cogs.registerObservationState(self)
    }

    boundary.access()
    return boundary
  }
}

extension Cogtext {
  /// Settles UI-read roots and notifies only values changed in this revision.
  ///
  /// Snapshot the count before settlement because a selector may lazily create
  /// another boundary while it runs. Such a boundary has established its own
  /// current baseline and joins the next flush; notifying it in the same pass
  /// could report a change predating its first observed value.
  internal func flushObservationBoundaries() {
    let boundaryCount = observationStates.count
    for state in observationStates.prefix(boundaryCount) {
      if state.settleState != .clean,
        let derived = state as? any DerivedCogSettleState
      {
        settle(derived)
      }

      let changedThisTurn = state.changedAt == revision
      #if DEBUG
      let changedBySeed = state.observationBoundary?.consumeDeferredChange() ?? false
      guard changedThisTurn || changedBySeed else { continue }
      historyLog.recordNotice(label: state.label, key: state.observationKey)
      #else
      guard changedThisTurn else { continue }
      #endif
      state.observationBoundary?.notifyChange()
    }
  }
}
