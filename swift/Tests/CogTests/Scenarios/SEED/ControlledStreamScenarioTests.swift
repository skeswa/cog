import Cog
import CogTesting
import Testing

private nonisolated enum ControlledStreamFailure: Error, Equatable {
  case disconnected
}

@MainActor
@Test func `SEED-10 ControlledStream announces consumption and drives exact generations`()
  async throws
{
  let cogs = Cogs.forTesting()
  let work = ControlledStream<Int>()
  let readingsCog = Cog<Int>.Async(.latest, default: -1, name: "readings") { _ in
    work.makeWork()
  }
  var starts = work.starts.makeAsyncIterator()

  let initial = cogs.status.peek(readingsCog)
  #expect(initial.kind == .pending)
  #expect(await starts.next() == 0)

  try await resolveAsyncStatus(in: cogs) { work.yield(5, to: 0) }
  let firstElement = cogs.status.peek(readingsCog)
  #expect(firstElement.kind == .success)
  #expect(firstElement.value == 5)

  // A natural end keeps the success and starts no work, as `generationCount`
  // proves. The next refresh creates and starts the next generation. The same
  // iterator observes it in order.
  try await resolveAsyncStatus(in: cogs) { work.finish(0) }
  #expect(cogs.status.peek(readingsCog).value == 5)
  #expect(work.generationCount == 1)

  _ = cogs.refresh(readingsCog)
  #expect(await starts.next() == 1)
  #expect(work.generationCount == 2)
  try await resolveAsyncStatus(in: cogs) {
    work.fail(1, with: ControlledStreamFailure.disconnected)
  }
  let failed = cogs.status.peek(readingsCog)
  #expect(failed.kind == .failure)
  #expect(failed.error as? ControlledStreamFailure == .disconnected)
  #expect(failed.value == 5)
}
