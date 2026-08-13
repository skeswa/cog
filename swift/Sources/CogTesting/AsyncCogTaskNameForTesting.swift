public import Cog

extension AsyncCog {
  /// Builds a keyed reference for verifying Cog's internal task name.
  ///
  /// This narrow diagnostic exists only until `AsyncCogBox` supplies the
  /// public keyed declaration API. Use it in tests that need to observe the
  /// descriptor-and-key name attached to an async cog's task.
  public func taskNameDiagnosticReference<Key: Hashable>(
    for key: Key
  ) -> AsyncCog<Value> {
    valueReferenceForTaskNameDiagnostic(key)
  }
}

/// Runtime task information exposed only by the `CogTesting` product.
public nonisolated enum CogTaskDiagnostic {
  /// The current Swift task's actual runtime name, when the runtime exposes it.
  ///
  /// Cog supports older OS releases where task creation accepts a name but the
  /// runtime cannot read it back. Host tests run on macOS 26 and use this
  /// property to prove the task itself received Cog's descriptor-derived name.
  public static var currentTaskName: String? {
    if #available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *) {
      return Task.name
    }
    return nil
  }
}
