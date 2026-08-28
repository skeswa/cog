import Cog
import CogTesting
import Testing

private nonisolated enum Async18Error: Error, Equatable {
  case offline
}

private nonisolated enum Async18Observation: Equatable {
  case initialPendingWithoutSuccess
  case pendingToFailureWithoutSuccess(Async18Error)
  case unexpectedTransition
}

@MainActor
@Test func `ASYNC-18 initial pending and failure are separate turns without previous values`()
  async
{
  let (cogs, m) = Cogs.forTestingWithController()
  let work = ControlledWork<Int>()
  let forecast = Cog<Int>.Async(default: 0, name: "forecast") { _ in
    work.makeWork()
  }
  let (observations, continuation) = AsyncStream.makeStream(of: Async18Observation.self)
  m.status.watch(forecast, initial: .run, name: "watch.forecast") { old, new in
    if old.kind == .pending, !old.hasSucceeded,
      new.kind == .pending, !new.hasSucceeded
    {
      continuation.yield(.initialPendingWithoutSuccess)
    } else if old.kind == .pending, !old.hasSucceeded,
      new.kind == .failure, !new.hasSucceeded
    {
      guard let error = new.error as? Async18Error else {
        continuation.yield(.unexpectedTransition)
        return
      }
      continuation.yield(.pendingToFailureWithoutSuccess(error))
    } else {
      continuation.yield(.unexpectedTransition)
    }
  }
  var iterator = observations.makeAsyncIterator()

  #expect(await iterator.next() == .initialPendingWithoutSuccess)

  var startIterator = work.starts.makeAsyncIterator()
  #expect(await startIterator.next() == 0)
  work.fail(0, with: Async18Error.offline)

  #expect(await iterator.next() == .pendingToFailureWithoutSuccess(.offline))

  #if DEBUG
  let statusTurns = cogs.debugHistory.entries.filter {
    $0.event == .turn && ($0.name == "forecast pending" || $0.name == "forecast failure")
  }
  #expect(statusTurns.map(\.name) == ["forecast pending", "forecast failure"])
  #expect(Set(statusTurns.map(\.turn)).count == 2)
  #endif

}
