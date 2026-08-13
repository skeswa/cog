/// Runtime task information exposed only by the `CogTesting` product.
///
/// Task names are a diagnostic implementation detail rather than Cog state or
/// shipping API. Keeping this seam in `CogTesting` lets behavior tests inspect
/// the actual Swift task from inside selected work without exposing task-local
/// machinery from `Cog`.
public nonisolated enum CogTaskDiagnostic {
  /// The current Swift task's actual runtime name, when this OS exposes it.
  ///
  /// Async work runs in a task named from its descriptor label and, for a keyed
  /// declaration, its key. Reading the runtime value rather than a mirrored Cog
  /// field proves that Instruments and other task tooling receive that rendered
  /// name. The property is `nonisolated`, so a test can call it from either
  /// MainActor-inherited work or an explicitly `@concurrent` work body.
  ///
  /// Cog supports deployment targets where task creation accepts a name but
  /// `Task.name` is unavailable. The seam returns `nil` there; this does not
  /// mean the task itself is unnamed. Host tests on a current runtime assert
  /// the exact name.
  public static var currentTaskName: String? {
    if #available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *) {
      return Task.name
    }
    return nil
  }
}
