/// One declaration-and-key step in a derived dependency cycle.
///
/// The descriptor identity preserves which declaration participated even when
/// two declarations share a human label. The label and key remain unrendered
/// until the rare failure path needs a message.
internal struct CogCycleStep {
  let descriptor: ObjectIdentifier
  let label: CogLabel
  let key: AnyHashable?

  init(node: any DerivedCogSettleNode) {
    self.descriptor = node.descriptorIdentity
    self.label = node.label
    self.key = node.key
  }

  var name: String {
    guard let key else { return "\(label)" }
    return "\(label)[\(key.base)]"
  }
}

/// The exact active-path suffix closed by one repeated derived read.
///
/// The closing node appears twice: `A -> A` is a self-cycle, while an active
/// path `[prefix, A, B]` that reads A reports only `A -> B -> A`. Keeping the
/// structure internal lets later CogTesting diagnostics expose behavior
/// without leaking node or stack representation.
internal struct CogCyclePath {
  let steps: [CogCycleStep]

  init(nodes: [any DerivedCogSettleNode]) {
    self.steps = nodes.map(CogCycleStep.init(node:))
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
/// Descriptor identities and nodes stay inside Cog. Tests need only the exact
/// human path and the message a real cycle failure would present.
package nonisolated struct CogCycleDiagnosticSnapshot: Sendable, Equatable {
  package let path: [String]
  package let message: String
}

extension Cogtext {
  /// Diagnoses whether reading `ref` now would close the active computation
  /// path, without creating a node, recording an edge, or taking the trap.
  package func cycleDiagnosticSnapshot<Value>(
    ifReading ref: Cog<Value>
  ) -> CogCycleDiagnosticSnapshot? {
    let identity = CogNodeIdentity(descriptor: ref.descriptor.identity, key: ref.key)
    guard let node = nodes[identity] as? any DerivedCogSettleNode else {
      return nil
    }
    return settleStack.cyclePath(ifEntering: node)?.snapshot
  }
}
