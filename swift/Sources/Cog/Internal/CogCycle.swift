/// One declaration-and-key step in a derived dependency cycle.
///
/// Descriptor identity distinguishes declarations that share a label. The
/// failure path renders the label and key on demand.
internal struct CogCycleStep {
  let descriptor: ObjectIdentifier
  let label: CogLabel
  let key: AnyHashable?

  init(state: any DerivedCogSettleState) {
    self.descriptor = state.descriptorIdentity
    self.label = state.label
    self.key = state.key
  }

  var name: String {
    guard let key else { return "\(label)" }
    return "\(label)[\(key.base)]"
  }
}

/// The exact active-path suffix closed by one repeated derived read.
///
/// The closing state appears twice. `A -> A` is a self-cycle; an active path
/// `[prefix, A, B]` that reads A reports `A -> B -> A`.
internal struct CogCyclePath {
  let steps: [CogCycleStep]

  init(states: [any DerivedCogSettleState]) {
    self.steps = states.map(CogCycleStep.init(state:))
  }

  var message: String {
    "Cog dependency cycle: \(steps.map(\.name).joined(separator: " -> "))."
  }

  var snapshot: CogCycleDiagnosticSnapshot {
    CogCycleDiagnosticSnapshot(
      path: steps.map(\.name),
      message: message
    )
  }
}

/// The rendered behavior that crosses from Cog into its testing product.
///
/// Tests receive the rendered path and failure message, not internal states.
package nonisolated struct CogCycleDiagnosticSnapshot: Sendable, Equatable {
  package let path: [String]
  package let message: String
}

extension Cogtext {
  /// Diagnoses whether reading `valueReference` now would close the active computation
  /// path, without creating a state, recording an edge, or taking the trap.
  package func cycleDiagnosticSnapshot<Value>(
    ifReading valueReference: Cog<Value>
  ) -> CogCycleDiagnosticSnapshot? {
    let identity = CogStateIdentity(
      descriptor: valueReference.descriptor.identity, key: valueReference.key)
    guard let state = states[identity] as? any DerivedCogSettleState else {
      return nil
    }
    return settleStack.cyclePath(ifEntering: state)?.snapshot
  }
}
