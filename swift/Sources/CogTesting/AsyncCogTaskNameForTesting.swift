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
