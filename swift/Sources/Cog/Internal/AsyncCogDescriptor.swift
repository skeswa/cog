/// The descriptor behind an async cog declaration.
internal final class AsyncCogDescriptor<Value>: CogDescriptor {
  let label: CogLabel
  let lifetime: CogStateLifetime
  let policy: LatestPolicy

  private let selector: @MainActor (Reader<CogPhase<Value>>, AnyHashable?) -> Work<Value>

  init(
    policy: LatestPolicy,
    selector: @escaping @MainActor (Reader<CogPhase<Value>>, AnyHashable?) -> Work<Value>,
    lifetime: CogStateLifetime = .whileObserved(grace: nil),
    label: CogLabel
  ) {
    self.label = label
    self.lifetime = lifetime
    self.policy = policy
    self.selector = selector
  }

  func makeWork(_ reader: Reader<CogPhase<Value>>, key: AnyHashable?) -> Work<Value> {
    selector(reader, key)
  }

  // Written out, and `nonisolated`, per the generic-class release rule.
  nonisolated deinit {}
}
