import Cog
import CogTesting
import Testing

@MainActor
@Test func `ASYNC-08 stale cancellation-ignoring result is rejected`() async throws {
  let (cogs, m) = Cogs.forTestingWithController()
  let request = Cog<Int>.Manual { 0 }
  let work = ControlledWork<Int>()
  let forecast = Cog<Int>.Async(default: 0, name: "forecast") { c in
    // The tracked read keeps the request dependency that replaces the run;
    // the controller's own generations index the work. Its operations ignore
    // cancellation exactly as this scenario needs: a superseded generation
    // still completes, and Cog must reject the stale result.
    _ = c[request]
    return work.makeWork()
  }
  let (statuses, continuation) = AsyncStream.makeStream(of: CogStatus<Int>.self)
  m.run { c in continuation.yield(c.status[forecast]) }
  var statusIterator = statuses.makeAsyncIterator()
  var startIterator = work.starts.makeAsyncIterator()

  _ = await statusIterator.next()
  #expect(await startIterator.next() == 0)
  cogs.turn("change request") { c in c[request] = 1 }
  _ = await statusIterator.next()
  #expect(await startIterator.next() == 1)

  let staleChecked = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAsyncCompletionCheck(with: staleChecked)
  work.succeed(0, with: 100)
  try await staleChecked.wait()

  let afterStale = cogs.status.peek(forecast)
  if afterStale.kind != .pending || afterStale.hasSucceeded {
    Issue.record("A stale result changed the newest run's pending status")
  }

  work.succeed(1, with: 200)
  guard let success = await statusIterator.next() else {
    Issue.record("The status stream ended before the newest result")
    return
  }
  if success.kind == .success {
    #expect(success.value == 200)
  } else {
    Issue.record("Expected only the newest result to turn")
  }
}
