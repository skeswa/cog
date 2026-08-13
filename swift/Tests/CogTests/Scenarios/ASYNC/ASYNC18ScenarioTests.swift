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
private final class Async18ControlledWork {
  private var continuation: CheckedContinuation<Int, any Error>?
  private var didStart = false
  private var startWaiter: CheckedContinuation<Void, Never>?

  func run() async throws -> Int {
    didStart = true
    startWaiter?.resume()
    startWaiter = nil
    return try await withCheckedThrowingContinuation { continuation = $0 }
  }

  func waitForStart() async {
    guard !didStart else { return }
    await withCheckedContinuation { startWaiter = $0 }
  }

  func fail(with error: any Error) {
    continuation?.resume(throwing: error)
    continuation = nil
  }
}

@MainActor
@Test func `ASYNC-18 initial pending and failure are separate turns without previous values`()
  async
{
  let cogs = Cogs.forTesting()
  let work = Async18ControlledWork()
  let forecast = AsyncCog<Int>(default: 0, name: "forecast") { _ in
    .run { try await work.run() }
  }
  let (observations, continuation) = AsyncStream.makeStream(of: Async18Observation.self)
  let token = cogs.meta.watch(forecast, initial: .run, name: "watch.forecast") { old, new in
    switch (old, new) {
    case (.pending(_, hasSucceeded: false), .pending(_, hasSucceeded: false)):
      continuation.yield(.initialPendingWithoutSuccess)
    case (
      .pending(_, hasSucceeded: false),
      .failure(let error, _, hasSucceeded: false)
    ):
      guard let error = error as? Async18Error else {
        continuation.yield(.unexpectedTransition)
        return
      }
      continuation.yield(.pendingToFailureWithoutSuccess(error))
    default:
      continuation.yield(.unexpectedTransition)
    }
  }
  var iterator = observations.makeAsyncIterator()

  #expect(await iterator.next() == .initialPendingWithoutSuccess)

  await work.waitForStart()
  work.fail(with: Async18Error.offline)

  #expect(await iterator.next() == .pendingToFailureWithoutSuccess(.offline))

  #if DEBUG
  let phaseTurns = cogs.debugHistory.entries.filter {
    $0.event == .turn && ($0.name == "forecast pending" || $0.name == "forecast failure")
  }
  #expect(phaseTurns.map(\.name) == ["forecast pending", "forecast failure"])
  #expect(Set(phaseTurns.map(\.turn)).count == 2)
  #endif

  withExtendedLifetime(token) {}
}
