import Cog
import CogTesting
import Testing

@MainActor
@Test func `ASYNC-03 reload preserves an explicit previous nil`() async {
  let (cogs, m) = Cogs.forTestingWithController()
  let request = Cog<Int>.Manual { 0 }
  let work = ControlledWork<Int?>()
  let forecast = Cog<Int?>.Async(default: nil, name: "forecast") { c in
    // The tracked read keeps the request dependency that drives the reload;
    // the controller's own generations index the work.
    _ = c[request]
    return work.makeWork()
  }
  let (statuses, continuation) = AsyncStream.makeStream(of: CogStatus<Int?>.self)
  m.run { c in continuation.yield(c.status[forecast]) }
  var statusIterator = statuses.makeAsyncIterator()
  var startIterator = work.starts.makeAsyncIterator()

  _ = await statusIterator.next()
  #expect(await startIterator.next() == 0)
  work.succeed(0, with: nil)

  guard let firstSuccess = await statusIterator.next() else {
    Issue.record("The status stream ended before the first success")
    return
  }
  if firstSuccess.kind == .success {
    #expect(firstSuccess.value == nil)
  } else {
    Issue.record("Expected a successful nil value")
  }

  cogs.turn("change request") { c in c[request] = 1 }

  guard let reload = await statusIterator.next() else {
    Issue.record("The status stream ended before reload pending")
    return
  }
  if reload.kind == .pending, reload.hasSucceeded {
    #expect(reload.value == nil)
  } else {
    Issue.record("Expected reload pending with an explicit previous nil")
  }

  #expect(await startIterator.next() == 1)
  work.succeed(1, with: 7)
  _ = await statusIterator.next()
}
