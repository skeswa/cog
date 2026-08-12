/// One async operation an ``AsyncCog`` can run.
public struct Work<Value> {
  /// The operation, preserving the actor context selected at its declaration.
  internal let operation: @Sendable @isolated(any) () async throws -> sending Value

  /// Describes one async value-producing operation.
  ///
  /// An unannotated body inherits the surrounding actor, which is normally the
  /// MainActor of an async selector. Expensive work can opt into the generic
  /// executor with `@concurrent`.
  public static func run(
    @_inheritActorContext
    _ operation: sending @escaping @Sendable @isolated(any) () async throws -> sending Value
  ) -> Self {
    Self(operation: operation)
  }
}

/// The replace-in-flight scheduling policy used by async cogs in the first slice.
public nonisolated enum LatestPolicy: Sendable, Equatable {
  /// Cancel old work and accept results only from the newest generation.
  case latest
}
