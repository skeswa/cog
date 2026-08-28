import Cog
import CogTesting
import Testing

@MainActor
@Test func `ASYNC-20 equal reload changes status but not value consumers`() async {
  let (cogs, m) = Cogs.forTestingWithController()
  let request = Cog<Int>.Manual { 0 }
  let work = ControlledWork<Int>()
  let forecast = Cog<Int>.Async(default: 0) { c in
    // The tracked read keeps the request dependency that drives the reload;
    // the controller's own generations index the work.
    _ = c[request]
    return work.makeWork()
  }
  var valueConsumerRuns = 0
  let valueConsumer = Cog<Int> { c in
    valueConsumerRuns += 1
    return c[forecast]
  }
  let (statuses, statusContinuation) = AsyncStream.makeStream(of: CogStatus<Int>.self)
  m.run { c in statusContinuation.yield(c.status[forecast]) }
  m.run { c in _ = c[valueConsumer] }
  var statusIterator = statuses.makeAsyncIterator()
  var startIterator = work.starts.makeAsyncIterator()

  guard let initialPending = await statusIterator.next(),
    initialPending.kind == .pending, !initialPending.hasSucceeded
  else {
    Issue.record("Expected initial pending without a previous value")
    return
  }
  #expect(valueConsumerRuns == 1)

  #expect(await startIterator.next() == 0)
  work.succeed(0, with: 42)
  guard let firstSuccess = await statusIterator.next(),
    firstSuccess.kind == .success, firstSuccess.value == 42
  else {
    Issue.record("Expected the first success")
    return
  }
  #expect(valueConsumerRuns == 2)

  cogs.turn { c in c[request] = 1 }
  guard let reloadPending = await statusIterator.next(),
    reloadPending.kind == .pending, reloadPending.value == 42, reloadPending.hasSucceeded
  else {
    Issue.record("Expected reload pending with the last successful value")
    return
  }
  #expect(valueConsumerRuns == 2)

  #expect(await startIterator.next() == 1)
  work.succeed(1, with: 42)
  guard let reloadSuccess = await statusIterator.next(),
    reloadSuccess.kind == .success, reloadSuccess.value == 42
  else {
    Issue.record("Expected the equal reload success")
    return
  }
  #expect(valueConsumerRuns == 2)

}
