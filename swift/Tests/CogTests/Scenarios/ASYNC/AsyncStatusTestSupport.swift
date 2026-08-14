import Cog
import CogTesting

/// Deterministic, generation-indexed async work shared by status scenarios.
///
/// Each call to ``makeWork()`` receives the next integer generation. Tests
/// await `starts` before completing that exact continuation, which prevents a
/// completion from racing work installation and keeps status assertions free
/// of sleeps or polling.
@MainActor
final class AsyncStatusControlledWork<Value: Sendable> {
  /// The generation IDs whose work operations have started.
  let starts: AsyncStream<Int>

  /// Publishes each generation when its operation begins.
  private let startContinuation: AsyncStream<Int>.Continuation

  /// Suspended operations indexed by the generation that owns them.
  private var continuations: [Int: CheckedContinuation<Value, any Error>] = [:]

  /// The generation assigned to the next selected operation.
  private var nextGeneration = 0

  /// Creates an empty controller whose first selected generation is zero.
  init() {
    (starts, startContinuation) = AsyncStream.makeStream(of: Int.self)
  }

  /// Returns work that announces and then suspends its assigned generation.
  func makeWork() -> Work<Value> {
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
  func succeed(_ generation: Int, with value: sending Value) {
    continuations.removeValue(forKey: generation)?.resume(returning: value)
  }

  /// Completes one started generation with an error.
  func fail(_ generation: Int, with error: any Error) {
    continuations.removeValue(forKey: generation)?.resume(throwing: error)
  }

  // Written explicitly per the generic-class release-build rule.
  nonisolated deinit {}
}

/// Runs one controlled completion and waits through Cog's generation check.
///
/// The acknowledgement fires after Cog accepts or rejects the result and any
/// accepted status publication has completed, making the following public read
/// deterministic.
@MainActor
func resolveAsyncStatus(
  in cogs: Cogs,
  _ completion: @MainActor () -> Void
) async throws {
  let checked = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAsyncCompletionCheck(with: checked)
  completion()
  try await checked.wait()
}
