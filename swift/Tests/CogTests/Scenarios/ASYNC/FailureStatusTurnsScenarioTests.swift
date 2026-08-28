import Cog
import CogTesting
import Testing

private nonisolated enum Async38Error: Error {
  case offline
}

@MainActor
@Test func `ASYNC-38 every failure is its own status turn while value consumers stay quiet`()
  async throws
{
  // The full-status lens has no equality gate. A retry that fails with an equal
  // error still cycles pending and failure as fresh turns. The
  // value projection keeps its own gate: the renderable value never changed,
  // so value consumers never rerun.
  let (cogs, m) = Cogs.forTestingWithController()
  let work = ControlledWork<Int>()
  let forecast = Cog<Int>.Async(default: 0, name: "forecast") { _ in work.makeWork() }
  var valueRuns = 0
  let projected = Cog<Int> { c in
    valueRuns += 1
    return c[forecast]
  }
  let (statuses, continuation) = AsyncStream.makeStream(of: CogStatus<Int>.self)
  m.run { c in continuation.yield(c.status[forecast]) }
  m.run { c in _ = c[projected] }
  var statusIterator = statuses.makeAsyncIterator()
  var startIterator = work.starts.makeAsyncIterator()

  guard let initialPending = await statusIterator.next(), initialPending.kind == .pending
  else {
    Issue.record("The status stream did not begin at pending")
    return
  }
  #expect(valueRuns == 1)
  #expect(await startIterator.next() == 0)

  try await resolveAsyncStatus(in: cogs) {
    work.fail(0, with: Async38Error.offline)
  }
  guard let firstFailure = await statusIterator.next(), firstFailure.kind == .failure else {
    Issue.record("The status stream did not observe the first failure")
    return
  }

  cogs.refresh(forecast)
  guard let retryPending = await statusIterator.next(), retryPending.kind == .pending else {
    Issue.record("The retry did not publish pending")
    return
  }
  #expect(await startIterator.next() == 1)

  try await resolveAsyncStatus(in: cogs) {
    work.fail(1, with: Async38Error.offline)
  }
  guard let secondFailure = await statusIterator.next(), secondFailure.kind == .failure else {
    Issue.record("The status stream did not observe the second failure")
    return
  }
  #expect(secondFailure.value == 0)
  #expect(!secondFailure.hasSucceeded)

  #if DEBUG
  let failureTurns = cogs.debugHistory.entries.filter {
    $0.event == .turn && $0.name == "forecast failure"
  }
  #expect(failureTurns.count == 2)
  #expect(Set(failureTurns.map(\.turn)).count == 2)
  #endif

  // The renderable value rested at the default throughout, so the value
  // consumer's single tracking run was its only run.
  #expect(valueRuns == 1)
}
