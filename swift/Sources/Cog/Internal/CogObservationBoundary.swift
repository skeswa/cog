import Observation

/// The Observation boundary for one UI-read Cog state.
///
/// Every boundary exposes the same phantom property. Its value is irrelevant;
/// the registrar uses its key path to connect a view read to a later changed
/// value notice. States that never reach the UI never allocate this object.
@MainActor
internal final class CogObservationBoundary: Observable {
  private let registrar = ObservationRegistrar()

  /// The one key path every boundary reports to Observation.
  private var value: Bool { false }

  /// Registers a read in the caller's active Observation tracking scope.
  func access() {
    registrar.access(self, keyPath: \.value)
  }

  /// Invalidates an active reader after the state really changed.
  func notifyChange() {
    registrar.withMutation(of: self, keyPath: \.value) {}
  }
}

/// State that may acquire a lazy UI observation boundary.
@MainActor
internal protocol CogObservationState: CogState {
  var observationBoundary: CogObservationBoundary? { get set }
}

extension CogObservationState {
  /// Gets or creates this state's boundary and records one UI read.
  @discardableResult
  func accessObservationBoundary() -> CogObservationBoundary {
    let boundary: CogObservationBoundary
    if let existing = observationBoundary {
      boundary = existing
    } else {
      boundary = CogObservationBoundary()
      observationBoundary = boundary
    }

    boundary.access()
    return boundary
  }
}

extension Cogtext {
  /// Settles UI-read roots and notifies only values changed in this revision.
  ///
  /// Snapshot the observed states before settlement because a selector may
  /// lazily create another state while it runs.
  internal func flushObservationBoundaries() {
    let observedStates = states.values.compactMap { state -> (any CogObservationState)? in
      guard
        let observed = state as? any CogObservationState,
        observed.observationBoundary != nil
      else { return nil }
      return observed
    }

    for state in observedStates {
      if state.settleState != .clean,
        let derived = state as? any DerivedCogSettleState
      {
        settle(derived)
      }

      guard state.changedAt == revision else { continue }
      state.observationBoundary?.notifyChange()
    }
  }
}
