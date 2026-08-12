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
}
