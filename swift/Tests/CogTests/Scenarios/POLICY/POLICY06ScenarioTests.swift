import Cog
import CogTesting
import Testing

/// Distinct failure used to prove the first queued refresh's exact outcome.
private nonisolated enum Policy06Error: Error, Equatable {
  case offline
}

@MainActor
@Test func `POLICY-06 queue continues after failure with exact refresh outcomes`() async throws {
  let (cogs, m) = probedContext()
  let work = PolicyGenerationControlledWork()
  let queuedCog = Cog<Int>.Async(.queue, default: -1, name: "queued") { _ in
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
