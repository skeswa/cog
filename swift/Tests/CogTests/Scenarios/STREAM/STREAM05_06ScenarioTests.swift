import Cog
import CogTesting
import Testing

@MainActor
private final class NaturalStreamWork {
  /// The live continuation for each stream generation selected so far.
  private var continuations: [AsyncStream<Int>.Continuation] = []

  /// How many independent stream generations the selector has created.
  var generationCount: Int { continuations.count }

  /// Creates one inert stream generation for the async selector.
  func makeWork() -> Work<Int> {
    let (sequence, continuation) = AsyncStream.makeStream(of: Int.self)
    continuations.append(continuation)
    return .stream(sequence)
  }

  /// Offers one element to the requested generation.
  func yield(_ value: Int, to generation: Int) {
    continuations[generation].yield(value)
  }

  /// Ends the requested generation normally.
  func finish(_ generation: Int) {
    continuations[generation].finish()
  }
}

@MainActor
@Test func `STREAM-05 natural end preserves success until explicit refresh`() async throws {
  let (cogs, m) = probedContext()
  let work = NaturalStreamWork()
  let readingsCog = AsyncCog<Int>(.latest, default: -1, name: "readings") { _ in
    work.makeWork()
  }
  var statuses: [CogStatus<Int>] = []
  m.status.watch(readingsCog, initial: .run, name: "watch.readings") { _, status in
    statuses.append(status)
  }

  try await resolveAsyncStatus(in: cogs) { work.yield(5, to: 0) }
  #if DEBUG
  let turnsBeforeEnd = cogs.debugHistory.entries.filter { $0.event == .turn }.count
  #endif
  try await resolveAsyncStatus(in: cogs) { work.finish(0) }

  #expect(work.generationCount == 1)
  #expect(statuses.map(\.kind) == [.pending, .success])
  #expect(statuses.map(\.value) == [-1, 5])
  let ended = cogs.status.peek(readingsCog)
  #expect(ended.kind == .success)
  #expect(ended.value == 5)
  #if DEBUG
  #expect(cogs.debugHistory.entries.filter { $0.event == .turn }.count == turnsBeforeEnd)
  #endif

  let refresh = cogs.refresh(readingsCog)
  #expect(work.generationCount == 2)
  let refreshing = cogs.status.peek(readingsCog)
  #expect(refreshing.kind == .pending)
  #expect(refreshing.value == 5)
  #expect(refreshing.hasSucceeded)

  try await resolveAsyncStatus(in: cogs) { work.yield(10, to: 1) }
  if case .success(let value) = await refresh.outcome {
    #expect(value == 10)
  } else {
    Issue.record("The refreshed stream did not resolve with its first element")
  }
  try await resolveAsyncStatus(in: cogs) { work.finish(1) }
}

@MainActor
@Test func `STREAM-06 empty natural end stays pending and can refresh`() async throws {
  let (cogs, m) = probedContext()
  let work = NaturalStreamWork()
  let readingsCog = AsyncCog<Int>(.latest, default: -1, name: "readings") { _ in
    work.makeWork()
  }
  var statuses: [CogStatus<Int>] = []
  m.status.watch(readingsCog, initial: .run, name: "watch.readings") { _, status in
    statuses.append(status)
  }

  #if DEBUG
  let turnsBeforeEnd = cogs.debugHistory.entries.filter { $0.event == .turn }.count
  #endif
  try await resolveAsyncStatus(in: cogs) { work.finish(0) }

  #expect(work.generationCount == 1)
  #expect(statuses.map(\.kind) == [.pending])
  let ended = cogs.status.peek(readingsCog)
  #expect(ended.kind == .pending)
  #expect(ended.value == -1)
  #expect(!ended.hasSucceeded)
  #expect(ended.isLoading)
  #if DEBUG
  #expect(cogs.debugHistory.entries.filter { $0.event == .turn }.count == turnsBeforeEnd)
  #endif

  let refresh = cogs.refresh(readingsCog)
  #expect(work.generationCount == 2)
  try await resolveAsyncStatus(in: cogs) { work.yield(6, to: 1) }
  if case .success(let value) = await refresh.outcome {
    #expect(value == 6)
  } else {
    Issue.record("The stream refreshed after empty termination did not succeed")
  }
  try await resolveAsyncStatus(in: cogs) { work.finish(1) }
}
