import Cog
import CogTesting
import Testing

@MainActor
@Test func `ASYNC-35 a dependency change resolves a live refresh handle as superseded`()
  async throws
{
  // ASYNC-21 proves a newer refresh supersedes a handle; this proves a
  // dependency change replaces the generation the same way. The handle
  // resolves as superseded at replacement and never drifts forward to the
  // dependency-started run, whose result alone may turn.
  let (cogs, m) = probedContext()
  let request = Cog<Int>.Manual { 0 }
  let work = AsyncStatusControlledWork<Int>()
  let forecast = Cog<Int>.Async(default: 0, name: "forecast") { c in
    _ = c[request]
    return work.makeWork()
  }
  let (statuses, continuation) = AsyncStream.makeStream(of: CogStatus<Int>.self)
  m.run { c in continuation.yield(c.status[forecast]) }
  var statusIterator = statuses.makeAsyncIterator()
  var startIterator = work.starts.makeAsyncIterator()

  guard let initialPending = await statusIterator.next(), initialPending.kind == .pending
  else {
    Issue.record("The status stream did not begin at pending")
    return
  }
  #expect(await startIterator.next() == 0)
  try await resolveAsyncStatus(in: cogs) {
    work.succeed(0, with: 10)
  }
  guard let firstSuccess = await statusIterator.next(), firstSuccess.kind == .success
  else {
    Issue.record("The status stream did not observe the first success")
    return
  }

  let refresh = cogs.refresh(forecast)
  guard let refreshPending = await statusIterator.next(), refreshPending.kind == .pending
  else {
    Issue.record("The refresh did not publish pending")
    return
  }
  #expect(await startIterator.next() == 1)

  cogs.turn("change request") { c in c[request] = 1 }
  if case .superseded = await refresh.outcome {
  } else {
    Issue.record("The dependency change did not resolve the refresh handle as superseded")
  }
  guard let replacementPending = await statusIterator.next(), replacementPending.kind == .pending
  else {
    Issue.record("The replacement did not publish pending")
    return
  }
  #expect(await startIterator.next() == 2)

  // The superseded generation's late result turns nothing; only the
  // dependency-started run may.
  try await resolveAsyncStatus(in: cogs) {
    work.succeed(1, with: 20)
  }
  let afterStale = cogs.status.peek(forecast)
  #expect(afterStale.kind == .pending)
  #expect(afterStale.value == 10)

  try await resolveAsyncStatus(in: cogs) {
    work.succeed(2, with: 30)
  }
  guard let finalSuccess = await statusIterator.next(), finalSuccess.kind == .success
  else {
    Issue.record("The status stream did not observe the replacement success")
    return
  }
  #expect(finalSuccess.value == 30)
}
