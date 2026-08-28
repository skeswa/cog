import Cog
import CogTesting
import Testing

@MainActor
private final class Async08ControlledWork {
  let starts: AsyncStream<Int>

  private let startContinuation: AsyncStream<Int>.Continuation
  private var continuations: [Int: CheckedContinuation<Int, Never>] = [:]

  init() {
    (starts, startContinuation) = AsyncStream.makeStream(of: Int.self)
  }

  func run(for request: Int) async -> Int {
    startContinuation.yield(request)
    return await withCheckedContinuation { continuations[request] = $0 }
  }

  func finish(_ request: Int, with value: Int) {
    continuations.removeValue(forKey: request)?.resume(returning: value)
  }
}

@MainActor
@Test func `ASYNC-08 stale cancellation-ignoring result is rejected`() async throws {
  let (cogs, m) = Cogs.forTestingWithController()
  let request = Cog<Int>.Manual { 0 }
  let work = Async08ControlledWork()
  let forecast = Cog<Int>.Async(default: 0, name: "forecast") { c in
    let currentRequest = c[request]
    return .run { await work.run(for: currentRequest) }
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
  work.finish(0, with: 100)
  try await staleChecked.wait()

  let afterStale = cogs.status.peek(forecast)
  if afterStale.kind != .pending || afterStale.hasSucceeded {
    Issue.record("A stale result changed the newest run's pending status")
  }

  work.finish(1, with: 200)
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
