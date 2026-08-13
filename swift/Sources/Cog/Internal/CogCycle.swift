/// One declaration-and-key step in a derived dependency cycle.
///
/// Descriptor identity distinguishes declarations that share a label. The
/// failure path renders the label and key on demand. Steps are captured only
/// after the MainActor-confined settle stack finds a repeated state, so this
/// diagnostic value never participates in graph identity or ownership.
internal struct CogCycleStep {
  /// Process identity of the declaration, retained only as a diagnostic discriminator.
  let descriptor: ObjectIdentifier
  /// Human-readable declaration label rendered if the cycle is reported.
  let label: CogLabel
  /// Erased state key, or `nil` for a keyless declaration.
  let key: AnyHashable?

  /// Captures diagnostic identity from one active derived state.
  init(state: any DerivedCogSettleState) {
    self.descriptor = state.descriptorIdentity
    self.label = state.label
    self.key = state.key
  }

  /// The declaration label plus key as it appears in a cycle path.
  var name: String {
    guard let key else { return "\(label)" }
    return "\(label)[\(key.base)]"
  }
}

/// The exact active-path suffix closed by one repeated derived read.
///
/// The closing state appears twice. `A -> A` is a self-cycle; an active path
/// `[prefix, A, B]` that reads A reports `A -> B -> A`. The path comes from the
/// states whose computations are still active, not from the raw enter/exit
/// frame buffer; nested settlement may empty its own frames while an enclosing
/// selector remains on this path.
internal struct CogCyclePath {
  /// Active computation suffix followed by its repeated closing state.
  let steps: [CogCycleStep]

  /// Captures the ordered states without retaining those state objects.
  init(states: [any DerivedCogSettleState]) {
    self.steps = states.map(CogCycleStep.init(state:))
  }

  /// The fatal diagnostic rendered from the captured steps.
  var message: String {
    "Cog dependency cycle: \(steps.map(\.name).joined(separator: " -> "))."
  }

  /// A state-free package snapshot suitable for the testing product.
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
  /// Rendered declaration-and-key names in cycle order, including the repeated close.
  package let path: [String]
  /// The exact fatal diagnostic production would emit for this cycle.
  package let message: String
}

extension Cogs {
  /// Diagnoses whether reading `valueReference` now would close the active computation
  /// path, without creating a state, recording an edge, or taking the trap.
  ///
  /// Requiring the exact descriptor-and-key state to exist keeps this testing
  /// seam observational: a diagnostic query cannot change later lazy creation,
  /// dependency order, lifetime, or history.
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
