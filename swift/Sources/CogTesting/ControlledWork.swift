public import Cog

/// Deterministic, generation-indexed one-shot async work for tests.
///
/// Completing work before Cog installs its continuation can lose the result.
/// This controller removes that race. Each ``makeWork()`` call takes the next
/// generation number. ``starts`` announces when Cog begins the operation, which
/// then waits for the test to complete that generation:
///
/// ```swift
/// let work = ControlledWork<Int>()
/// let forecastCog = Cog<Int>.Async(default: 0, name: "forecast") { _ in
///   work.makeWork()
/// }
/// var starts = work.starts.makeAsyncIterator()
///
/// cogs.refresh(forecastCog)
/// #expect(await starts.next() == 0)
/// work.succeed(0, with: 72)
/// ```
///
/// Await ``starts`` before completing work instead of sleeping or polling.
/// Generation numbers keep stale and current results separate. Completion
/// resumes the operation; acknowledgement hooks tell the test whether Cog
/// accepted it.
///
/// Identity and lifetime are the test's: the controller is a MainActor class
/// the test retains alongside its runtime, and it holds only continuations for
/// generations that have started and not yet completed.
@MainActor
public final class ControlledWork<Value: Sendable> {
  /// The generation IDs whose work operations have started, in start order.
  public let starts: AsyncStream<Int>

  /// Publishes each generation when its operation begins.
  private let startContinuation: AsyncStream<Int>.Continuation

  /// Suspended operations indexed by the generation that owns them.
  private var continuations: [Int: CheckedContinuation<Value, any Error>] = [:]

  /// The generation assigned to the next selected operation.
  private var nextGeneration = 0

  /// Creates an empty controller whose first selected generation is zero.
  public init() {
    (starts, startContinuation) = AsyncStream.makeStream(of: Int.self)
  }

  /// Returns work that announces and then suspends its assigned generation.
  ///
  /// Call this from an async selector, once per selector run. The generation
  /// is assigned here. ``starts`` announces it only when Cog begins the
  /// operation, so tests can tell selected work from started work.
  public func makeWork() -> Work<Value> {
    let generation = nextGeneration
    nextGeneration += 1
    return .run {
      self.startContinuation.yield(generation)
      return try await withCheckedThrowingContinuation {
        self.continuations[generation] = $0
      }
    }
  }

  /// Completes one started generation successfully.
  ///
  /// Completing a generation that has not started, or completing one twice,
  /// does nothing: the continuation either does not exist yet or was already
  /// consumed. Await ``starts`` first to make completion deterministic.
  public func succeed(_ generation: Int, with value: sending Value) {
    continuations.removeValue(forKey: generation)?.resume(returning: value)
  }

  /// Completes one started generation with an error.
  ///
  /// The same no-op rule as ``succeed(_:with:)`` applies to unknown or
  /// already-completed generations.
  public func fail(_ generation: Int, with error: any Error) {
    continuations.removeValue(forKey: generation)?.resume(throwing: error)
  }

  // Written explicitly per the generic-class release-build rule.
  nonisolated deinit {}
}
