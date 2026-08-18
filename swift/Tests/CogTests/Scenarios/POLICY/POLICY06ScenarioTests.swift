import Cog
import CogTesting
import Testing

/// Distinct failure used to prove the first queued refresh's exact outcome.
private nonisolated enum Policy06Error: Error, Equatable {
  case offline
}

/// Deterministic ordered work indexed by selector generation.
@MainActor
private final class Policy06ControlledWork {
  /// Announces only when an operation actually begins executing.
  let starts: AsyncStream<Int>

  /// Feeds operation starts to the test in exact generation order.
  private let startContinuation: AsyncStream<Int>.Continuation

  /// Started operations awaiting an exact success or failure.
  private var continuations: [Int: CheckedContinuation<Int, any Error>] = [:]

  /// Generation assigned to the next selected operation.
  private var nextGeneration = 0

  /// Creates a probe with no selected or running work.
  init() {
    (starts, startContinuation) = AsyncStream.makeStream(of: Int.self)
  }

  /// Describes one run that announces and then suspends its generation.
  func makeRun() -> RunWork<Int> {
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
  func succeed(_ generation: Int, with value: Int) {
    continuations.removeValue(forKey: generation)?.resume(returning: value)
  }

  /// Completes one started generation with an error.
  func fail(_ generation: Int, with error: any Error) {
    continuations.removeValue(forKey: generation)?.resume(throwing: error)
  }

  nonisolated deinit {}
}

@MainActor
@Test func `POLICY-06 queue continues after failure with exact refresh outcomes`() async throws {
  let (cogs, m) = probedContext()
  let work = Policy06ControlledWork()
  let queuedCog = AsyncCog<Int>(.queue, default: -1, name: "queued") { _ in
    work.makeRun()
  }
  var statuses: [CogStatus<Int>] = []
  m.status.watch(queuedCog, initial: .run, name: "watch.queued") { _, status in
    statuses.append(status)
  }
  var starts = work.starts.makeAsyncIterator()

  #expect(await starts.next() == 0)
  try await resolveAsyncStatus(in: cogs) { work.succeed(0, with: 42) }
  statuses.removeAll()

  let failedRefresh = cogs.refresh(queuedCog)
  let successfulRefresh = cogs.refresh(queuedCog)
  #expect(await starts.next() == 1)

  try await resolveAsyncStatus(in: cogs) {
    work.fail(1, with: Policy06Error.offline)
  }
  if case .failure(let error) = await failedRefresh.outcome {
    #expect(error as? Policy06Error == .offline)
  } else {
    Issue.record("The failed queue head did not resolve its own refresh as failure")
  }

  #expect(await starts.next() == 2)
  try await resolveAsyncStatus(in: cogs) { work.succeed(2, with: 84) }
  if case .success(let value) = await successfulRefresh.outcome {
    #expect(value == 84)
  } else {
    Issue.record("The queued successor did not resolve its own refresh as success")
  }

  #expect(statuses.map(\.kind) == [.pending, .failure, .pending, .success])
  #expect(statuses.map(\.value) == [42, 42, 42, 84])
  #expect(statuses.dropFirst().first?.error as? Policy06Error == .offline)
}
