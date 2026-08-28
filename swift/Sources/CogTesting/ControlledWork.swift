public import Cog

/// Deterministic, generation-indexed one-shot async work for tests.
///
/// An async cog's selector runs once per generation, and a test that completes
/// work "as soon as possible" races Cog's installation of that work: a value
/// resumed before the generation's continuation exists is silently lost. This
/// controller removes the race. Each ``makeWork()`` call takes the next
/// integer generation, announces it on ``starts`` when Cog actually begins the
/// operation, and suspends until the test completes that exact generation:
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
/// Awaiting ``starts`` before completing keeps status assertions free of
/// sleeps and polling, and generation indexing keeps a superseded completion
/// from being mistaken for the current one. Completion resolves the awaited
/// operation; observing Cog's acceptance of the result remains the
/// acknowledgement hooks' job.
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
  /// is assigned here, but ``starts`` announces it only when Cog begins the
  /// operation — the difference is what lets a test distinguish selected work
  /// from started work.
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
