/// A deferred async operation selected for one ``AsyncCog`` generation.
///
/// `Work` describes execution; creating it does not start a `Task`. An async
/// selector returns a fresh value after synchronously recording its Cog
/// dependencies. Cog then owns the task, cancellation, generation checks, and
/// MainActor publication of the resulting phase.
///
/// The operation may throw and may return a non-`Sendable` value when Swift's
/// region-based `sending` rules prove the transfer safe. Replacement and
/// lifetime cancellation are advisory to the operation, but Cog rejects every
/// completion that no longer belongs to the current stored generation.
public struct Work<Value> {
  /// The deferred operation with the isolation inherited at its declaration.
  internal let operation: @Sendable @isolated(any) () async throws -> sending Value

  /// Describes one deferred, throwing value-producing operation.
  ///
  /// The body does not run during this call. An unannotated body inherits the
  /// surrounding actor, normally the MainActor of an async selector, which is
  /// useful for async APIs isolated there. CPU-intensive or blocking work
  /// should not occupy the MainActor; an explicitly `@concurrent` body opts
  /// into the generic executor instead.
  ///
  /// Regardless of operation isolation, Cog observes completion and publishes
  /// success or failure on the MainActor. If newer work or lifetime release has
  /// superseded this operation, its completion publishes nothing.
  ///
  /// - Parameter operation: The deferred operation for this generation. It
  ///   should cooperate with cancellation when practical, though correctness
  ///   does not depend on that cooperation.
  /// - Returns: A work description for the async selector to return to Cog.
  public static func run(
    @_inheritActorContext
    _ operation: sending @escaping @Sendable @isolated(any) () async throws -> sending Value
  ) -> Self {
    Self(operation: operation)
  }
}

/// How an async state schedules new work while prior work is in flight.
///
/// Policies are part of declaration behavior and apply independently to each
/// key of an ``AsyncCogBox``. The initial API offers only replacement semantics;
/// later policies can expand this enum without changing phase or work types.
public nonisolated enum LatestPolicy: Sendable, Equatable {
  /// Cancel prior work and accept a result only from the newest generation.
  ///
  /// Every reload publishes pending as its next visible phase, advances a
  /// monotonically increasing generation, and requests cancellation of the old
  /// task. If the old task ignores cancellation and completes, the generation
  /// check discards its result. Replacement cancellation itself never publishes
  /// failure.
  case latest
}
