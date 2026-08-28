import Cog
import CogTesting
import Testing

private nonisolated enum Async19Error: Error, Equatable {
  case offline
}

@MainActor
@Test func `ASYNC-19 failures and repeated reloads retain the last success`() async {
  let (cogs, m) = Cogs.forTestingWithController()
  let request = Cog<Int>.Manual { 0 }
  let work = ControlledWork<Int>()
  let forecast = Cog<Int>.Async(default: 0, name: "forecast") { c in
    // The tracked read keeps the request dependency that drives each reload;
    // the controller's own generations index the work.
    _ = c[request]
    return work.makeWork()
  }
  let (statuses, continuation) = AsyncStream.makeStream(of: CogStatus<Int>.self)
  m.run { c in continuation.yield(c.status[forecast]) }
  var statusIterator = statuses.makeAsyncIterator()
  var startIterator = work.starts.makeAsyncIterator()

  _ = await statusIterator.next()
  #expect(await startIterator.next() == 0)
  work.succeed(0, with: 10)

  guard let firstSuccess = await statusIterator.next() else {
    Issue.record("The status stream ended before success")
    return
  }
  if firstSuccess.kind == .success {
    #expect(firstSuccess.value == 10)
  } else {
    Issue.record("Expected the first work to succeed")
  }

  cogs.turn("first reload") { c in c[request] = 1 }
  guard let failedReloadPending = await statusIterator.next() else {
    Issue.record("The status stream ended before reload pending")
    return
  }
  if failedReloadPending.kind == .pending, failedReloadPending.hasSucceeded {
    #expect(failedReloadPending.value == 10)
  } else {
    Issue.record("Expected reload pending to retain the last success")
  }
  #expect(await startIterator.next() == 1)
  work.fail(1, with: Async19Error.offline)

  guard let failure = await statusIterator.next() else {
    Issue.record("The status stream ended before failure")
    return
  }
  if failure.kind == .failure, failure.hasSucceeded {
    #expect(failure.error as? Async19Error == .offline)
    #expect(failure.value == 10)
  } else {
    Issue.record("Expected failure to retain the last success")
  }

  cogs.turn("second reload") { c in c[request] = 2 }
  guard let repeatedReload = await statusIterator.next() else {
    Issue.record("The status stream ended before repeated reload pending")
    return
  }
  if repeatedReload.kind == .pending, repeatedReload.hasSucceeded {
    #expect(repeatedReload.value == 10)
  } else {
    Issue.record("Expected a later reload to retain success rather than failure")
  }
  #expect(await startIterator.next() == 2)

  #if DEBUG
  let statusTurns = cogs.debugHistory.entries.filter {
    $0.event == .turn && $0.name.hasPrefix("forecast ")
  }
  #expect(
    statusTurns.map(\.name) == [
      "forecast pending",
      "forecast success",
      "forecast pending",
      "forecast failure",
      "forecast pending",
    ]
  )
  #expect(Set(statusTurns.map(\.turn)).count == 5)
  #endif
}
