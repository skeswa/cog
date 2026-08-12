import Cog
import CogTesting
import Testing

@MainActor
private final class Async03ControlledWork {
  private var continuations: [Int: CheckedContinuation<Int?, any Error>] = [:]
  private let startContinuation: AsyncStream<Int>.Continuation
  let starts: AsyncStream<Int>

  init() {
    (starts, startContinuation) = AsyncStream.makeStream(of: Int.self)
  }

  func run(for request: Int) async throws -> Int? {
    startContinuation.yield(request)
    return try await withCheckedThrowingContinuation {
      continuations[request] = $0
    }
  }

  func succeed(_ request: Int, with value: Int?) {
    continuations.removeValue(forKey: request)?.resume(returning: value)
  }
}

@MainActor
@Test func `ASYNC-03 reload preserves an explicit previous nil`() async {
  let cogs = Cogtext.forTesting()
  let request = ManualCog<Int>(0)
  let work = Async03ControlledWork()
  let forecast = AsyncCog<Int?>(name: "forecast") { c in
    let currentRequest = c[request]
    return .run { try await work.run(for: currentRequest) }
  }
  let (phases, continuation) = AsyncStream.makeStream(of: CogPhase<Int?>.self)
  let token = cogs.run { c in continuation.yield(c[forecast]) }
  var phaseIterator = phases.makeAsyncIterator()
  var startIterator = work.starts.makeAsyncIterator()

  _ = await phaseIterator.next()
  #expect(await startIterator.next() == 0)
  work.succeed(0, with: nil)

  guard let firstSuccess = await phaseIterator.next() else {
    Issue.record("The phase stream ended before the first success")
    return
  }
  if case .success(let value) = firstSuccess {
    #expect(value == nil)
  } else {
    Issue.record("Expected a successful nil value")
  }

  cogs.commit("change request") { c in c[request] = 1 }

  guard let reload = await phaseIterator.next() else {
    Issue.record("The phase stream ended before reload pending")
    return
  }
  switch reload {
  case .pending(previous: .some(let value)):
    #expect(value == nil)
  default:
    Issue.record("Expected reload pending with an explicit previous nil")
  }

  #expect(await startIterator.next() == 1)
  work.succeed(1, with: 7)
  _ = await phaseIterator.next()
  withExtendedLifetime(token) {}
}
