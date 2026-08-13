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
  let cogs = Cogtext.forTesting()
  let request = ManualCog<Int>(0)
  let work = Async08ControlledWork()
  let forecast = AsyncCog<Int>(default: 0, name: "forecast") { c in
    let currentRequest = c[request]
    return .run { await work.run(for: currentRequest) }
  }
  let (phases, continuation) = AsyncStream.makeStream(of: CogPhase<Int>.self)
  let token = cogs.run { c in continuation.yield(c.phase[forecast]) }
  var phaseIterator = phases.makeAsyncIterator()
  var startIterator = work.starts.makeAsyncIterator()

  _ = await phaseIterator.next()
  #expect(await startIterator.next() == 0)
  cogs.commit("change request") { c in c[request] = 1 }
  _ = await phaseIterator.next()
  #expect(await startIterator.next() == 1)

  let staleChecked = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAsyncCompletionCheck(with: staleChecked)
  work.finish(0, with: 100)
  try await staleChecked.wait()

  let afterStale = cogs.phase.peek(forecast)
  if case .pending(previous: .none) = afterStale {
  } else {
    Issue.record("A stale result changed the newest run's pending phase")
  }

  work.finish(1, with: 200)
  guard let success = await phaseIterator.next() else {
    Issue.record("The phase stream ended before the newest result")
    return
  }
  if case .success(let value) = success {
    #expect(value == 200)
  } else {
    Issue.record("Expected only the newest result to commit")
  }
  withExtendedLifetime(token) {}
}
