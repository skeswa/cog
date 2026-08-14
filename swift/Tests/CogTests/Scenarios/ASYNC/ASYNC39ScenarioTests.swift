import Cog
import CogTesting
import Testing

@MainActor
@Test func `ASYNC-39 a CancellationError from an uncancelled current run is a failure`()
  async throws
{
  // ASYNC-09 and ASYNC-13 prove Cog's own cancellation publishes nothing. The
  // converse must stay honest: when work that is still the newest run — and
  // whose task Cog never cancelled — rethrows a CancellationError from some
  // inner operation, that is an ordinary failure, not a silent forever-pending
  // state.
  let (cogs, m) = probedContext()
  let work = AsyncStatusControlledWork<Int>()
  let forecast = AsyncCog<Int>(default: 0, name: "forecast") { _ in work.makeWork() }
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
    work.fail(0, with: CancellationError())
  }
  guard let failure = await statusIterator.next(), failure.kind == .failure else {
    Issue.record("The rethrown CancellationError did not publish a failure")
    return
  }
  #expect(failure.error is CancellationError)
  #expect(failure.value == 0)
  #expect(!failure.hasSucceeded)
  #expect(!failure.isLoading)
}
