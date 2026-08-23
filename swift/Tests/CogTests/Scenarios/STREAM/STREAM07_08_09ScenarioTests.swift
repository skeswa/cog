import Cog
import CogTesting
import Testing

private nonisolated enum StreamFailure: Error, Equatable {
  case disconnected
}

@MainActor
private final class ThrowingStreamWork {
  /// The live continuation for each selected stream generation.
  private var continuations: [AsyncThrowingStream<Int, any Error>.Continuation] = []

  /// How many independent stream generations the selector has created.
  var generationCount: Int { continuations.count }

  /// Creates one controllable throwing stream generation.
  func makeWork() -> Work<Int> {
    var storedContinuation: AsyncThrowingStream<Int, any Error>.Continuation?
    let sequence = AsyncThrowingStream<Int, any Error> { continuation in
      storedContinuation = continuation
    }
    guard let storedContinuation else {
      fatalError("AsyncThrowingStream did not synchronously install its continuation.")
    }
    continuations.append(storedContinuation)
    return .stream(sequence)
  }

  /// Offers one element to the requested generation.
  func yield(_ value: Int, to generation: Int) {
    continuations[generation].yield(value)
  }

  /// Terminates the requested generation with an error.
  func fail(_ generation: Int, with error: any Error) {
    continuations[generation].finish(throwing: error)
  }
}

@MainActor
@Test func `STREAM-07 current stream failure before first element is terminal`() async throws {
  let (cogs, m) = probedContext()
  let work = ThrowingStreamWork()
  let readingsCog = Cog<Int>.Async(.latest, default: -1, name: "readings") { _ in
    work.makeWork()
  }
  let refresh = cogs.refresh(readingsCog)
  var statuses: [CogStatus<Int>] = []
  m.status.watch(readingsCog, initial: .run, name: "watch.readings") { _, status in
    statuses.append(status)
  }

  try await resolveAsyncStatus(in: cogs) {
    work.fail(0, with: StreamFailure.disconnected)
  }

  #expect(work.generationCount == 1)
  #expect(statuses.map(\.kind) == [.pending, .failure])
  let failed = cogs.status.peek(readingsCog)
  #expect(failed.value == -1)
  #expect(!failed.hasSucceeded)
  #expect(failed.error as? StreamFailure == .disconnected)
  if case .failure(let error) = await refresh.outcome {
    #expect(error as? StreamFailure == .disconnected)
  } else {
    Issue.record("The exact stream refresh did not retain its failure")
  }
}

@MainActor
@Test func `STREAM-08 later stream failure retains its first accepted element`() async throws {
  let (cogs, m) = probedContext()
  let work = ThrowingStreamWork()
  let readingsCog = Cog<Int>.Async(.latest, default: -1, name: "readings") { _ in
    work.makeWork()
  }
  var statuses: [CogStatus<Int>] = []
  m.status.watch(readingsCog, initial: .run, name: "watch.readings") { _, status in
    statuses.append(status)
  }

  try await resolveAsyncStatus(in: cogs) { work.yield(5, to: 0) }
  let cancelled = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAsyncCompletionCheck(with: cancelled)
  let refresh = cogs.refresh(readingsCog)
  try await cancelled.wait()

  try await resolveAsyncStatus(in: cogs) { work.yield(10, to: 1) }
  if case .success(let value) = await refresh.outcome {
    #expect(value == 10)
  } else {
    Issue.record("The refreshed stream did not resolve from its first element")
  }
  try await resolveAsyncStatus(in: cogs) {
    work.fail(1, with: StreamFailure.disconnected)
  }

  #expect(work.generationCount == 2)
  let failed = cogs.status.peek(readingsCog)
  #expect(failed.kind == .failure)
  #expect(failed.value == 10)
  #expect(failed.hasSucceeded)
  #expect(failed.error as? StreamFailure == .disconnected)
  #expect(statuses.map(\.kind) == [.pending, .success, .pending, .success, .failure])
}

/// A sequence whose only iteration suspends until task cancellation throws.
///
/// Reporting entry before the cancellable sleep lets the scenario prove Cog
/// caused the eventual `CancellationError`, rather than merely racing a task
/// that had not started iteration yet.
private nonisolated struct CancellationProbeSequence: AsyncSequence, Sendable {
  typealias Element = Int

  /// Identifies the generation reported when iteration begins.
  let generation: Int

  /// Publishes that iteration reached its cancellable suspension.
  let startContinuation: AsyncStream<Int>.Continuation

  func makeAsyncIterator() -> Iterator {
    Iterator(generation: generation, startContinuation: startContinuation)
  }

  /// The single-use iterator owned by Cog's stream task.
  struct Iterator: AsyncIteratorProtocol {
    /// Identifies the generation this iterator belongs to.
    let generation: Int

    /// Publishes entry into ``next()`` before suspension.
    let startContinuation: AsyncStream<Int>.Continuation

    mutating func next() async throws -> Int? {
      startContinuation.yield(generation)
      try await Task.sleep(for: .seconds(3_600))
      return nil
    }
  }
}

@MainActor
private final class CancellationStreamWork {
  /// Announces when the first generation begins its cancellable iteration.
  let starts: AsyncStream<Int>

  /// Backs ``starts`` and is safe to copy into the nonisolated probe sequence.
  private let startContinuation: AsyncStream<Int>.Continuation

  /// Terminates the replacement generation from the test.
  private var replacementContinuation: AsyncThrowingStream<Int, any Error>.Continuation?

  /// The generation number assigned by the next selector run.
  private var nextGeneration = 0

  init() {
    (starts, startContinuation) = AsyncStream.makeStream(of: Int.self)
  }

  /// Returns a cancellation-reactive first stream, then a controlled replacement.
  func makeWork() -> Work<Int> {
    defer { nextGeneration += 1 }
    if nextGeneration == 0 {
      return .stream(
        CancellationProbeSequence(
          generation: nextGeneration,
          startContinuation: startContinuation
        )
      )
    }

    let sequence = AsyncThrowingStream<Int, any Error> { continuation in
      replacementContinuation = continuation
    }
    return .stream(sequence)
  }

  /// Throws `CancellationError` from the still-current replacement stream.
  func failCurrentWithCancellation() {
    replacementContinuation?.finish(throwing: CancellationError())
  }
}

@MainActor
@Test func `STREAM-09 only Cog-caused cancellation stays silent`() async throws {
  let (cogs, m) = probedContext()
  let work = CancellationStreamWork()
  let readingsCog = Cog<Int>.Async(.latest, default: -1, name: "readings") { _ in
    work.makeWork()
  }
  var statuses: [CogStatus<Int>] = []
  m.status.watch(readingsCog, initial: .run, name: "watch.readings") { _, status in
    statuses.append(status)
  }
  var startIterator = work.starts.makeAsyncIterator()
  #expect(await startIterator.next() == 0)

  let cancelled = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAsyncCompletionCheck(with: cancelled)
  let refresh = cogs.refresh(readingsCog)
  try await cancelled.wait()

  #expect(statuses.allSatisfy { $0.kind != .failure })
  let replacement = cogs.status.peek(readingsCog)
  #expect(replacement.kind == .pending)
  #expect(replacement.error == nil)

  try await resolveAsyncStatus(in: cogs) { work.failCurrentWithCancellation() }
  let failed = cogs.status.peek(readingsCog)
  #expect(failed.kind == .failure)
  #expect(failed.error is CancellationError)
  if case .failure(let error) = await refresh.outcome {
    #expect(error is CancellationError)
  } else {
    Issue.record("A current CancellationError did not resolve as an ordinary failure")
  }
}
