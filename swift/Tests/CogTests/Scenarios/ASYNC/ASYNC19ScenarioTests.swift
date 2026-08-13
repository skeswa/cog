import Cog
import CogTesting
import Testing

private nonisolated enum Async19Error: Error, Equatable {
  case offline
}

@MainActor
private final class Async19ControlledWork {
  let starts: AsyncStream<Int>

  private let startContinuation: AsyncStream<Int>.Continuation
  private var continuations: [Int: CheckedContinuation<Int, any Error>] = [:]

  init() {
    (starts, startContinuation) = AsyncStream.makeStream(of: Int.self)
  }

  func run(for request: Int) async throws -> Int {
    startContinuation.yield(request)
    return try await withCheckedThrowingContinuation { continuations[request] = $0 }
  }

  func succeed(_ request: Int, with value: Int) {
    continuations.removeValue(forKey: request)?.resume(returning: value)
  }

  func fail(_ request: Int, with error: any Error) {
    continuations.removeValue(forKey: request)?.resume(throwing: error)
  }
}

@MainActor
@Test func `ASYNC-19 failures and repeated reloads retain the last success`() async {
  let cogs = Cogs.forTesting()
  let request = ManualCog<Int>(0)
  let work = Async19ControlledWork()
  let forecast = AsyncCog<Int>(default: 0, name: "forecast") { c in
    let currentRequest = c[request]
    return .run { try await work.run(for: currentRequest) }
  }
  let (phases, continuation) = AsyncStream.makeStream(of: CogMeta<Int>.self)
  let token = cogs.run { c in continuation.yield(c.meta[forecast]) }
  var phaseIterator = phases.makeAsyncIterator()
  var startIterator = work.starts.makeAsyncIterator()

  _ = await phaseIterator.next()
  #expect(await startIterator.next() == 0)
  work.succeed(0, with: 10)

  guard let firstSuccess = await phaseIterator.next() else {
    Issue.record("The phase stream ended before success")
    return
  }
  if case .success(let value) = firstSuccess {
    #expect(value == 10)
  } else {
    Issue.record("Expected the first work to succeed")
  }

  cogs.commit("first reload") { c in c[request] = 1 }
  guard let failedReloadPending = await phaseIterator.next() else {
    Issue.record("The phase stream ended before reload pending")
    return
  }
  if case .pending(value: let value, hasSucceeded: true) = failedReloadPending {
    #expect(value == 10)
  } else {
    Issue.record("Expected reload pending to retain the last success")
  }
  #expect(await startIterator.next() == 1)
  work.fail(1, with: Async19Error.offline)

  guard let failure = await phaseIterator.next() else {
    Issue.record("The phase stream ended before failure")
    return
  }
  switch failure {
  case .failure(let error, let value, hasSucceeded: true):
    #expect(error as? Async19Error == .offline)
    #expect(value == 10)
  default:
    Issue.record("Expected failure to retain the last success")
  }

  cogs.commit("second reload") { c in c[request] = 2 }
  guard let repeatedReload = await phaseIterator.next() else {
    Issue.record("The phase stream ended before repeated reload pending")
    return
  }
  if case .pending(value: let value, hasSucceeded: true) = repeatedReload {
    #expect(value == 10)
  } else {
    Issue.record("Expected a later reload to retain success rather than failure")
  }
  #expect(await startIterator.next() == 2)

  #if DEBUG
  let phaseTurns = cogs.debugHistory.entries.filter {
    $0.event == .turn && $0.name.hasPrefix("forecast ")
  }
  #expect(
    phaseTurns.map(\.name) == [
      "forecast pending",
      "forecast success",
      "forecast pending",
      "forecast failure",
      "forecast pending",
    ]
  )
  #expect(Set(phaseTurns.map(\.turn)).count == 5)
  #endif
  withExtendedLifetime(token) {}
}
