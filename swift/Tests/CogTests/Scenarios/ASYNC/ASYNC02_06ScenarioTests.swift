import Cog
import CogTesting
import Testing

private nonisolated enum Async02Error: Error, Equatable {
  case offline
}

@MainActor
private final class Async02ControlledWork {
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

  func succeed(with value: Int) {
    continuation?.resume(returning: value)
    continuation = nil
  }

  func fail(with error: any Error) {
    continuation?.resume(throwing: error)
    continuation = nil
  }
}

@MainActor
@Test func `ASYNC-02 thrown work publishes a failure holding its error`() async {
  let cogs = Cogtext.forTesting()
  let work = Async02ControlledWork()
  let forecast = AsyncCog<Int>(name: "forecast") { _ in
    .run { try await work.run() }
  }
  let (phases, continuation) = AsyncStream.makeStream(of: CogPhase<Int>.self)
  let token = cogs.run { c in continuation.yield(c[forecast]) }
  var iterator = phases.makeAsyncIterator()

  guard let pending = await iterator.next() else {
    Issue.record("The phase stream ended before pending")
    return
  }
  if case .pending(previous: .none) = pending {
  } else {
    Issue.record("Expected initial pending without a previous value")
  }

  await work.waitForStart()
  work.fail(with: Async02Error.offline)

  guard let failure = await iterator.next() else {
    Issue.record("The phase stream ended before failure")
    return
  }
  switch failure {
  case .failure(let error, previous: .none):
    #expect(error as? Async02Error == .offline)
  default:
    Issue.record("Expected failure without a previous value")
  }

  #if DEBUG
  let failureTurns = cogs.debugHistory.entries.filter {
    $0.event == .turn && $0.name == "forecast failure"
  }
  #expect(failureTurns.count == 1)
  #endif
  withExtendedLifetime(token) {}
}

@MainActor
@Test func `ASYNC-06 watcher sees pending and success in separate named turns`() async {
  let cogs = Cogtext.forTesting()
  let work = Async02ControlledWork()
  let forecast = AsyncCog<Int>(name: "forecast") { _ in
    .run { try await work.run() }
  }
  let (phases, continuation) = AsyncStream.makeStream(of: CogPhase<Int>.self)
  let token = cogs.run { c in continuation.yield(c[forecast]) }
  var iterator = phases.makeAsyncIterator()

  guard let pending = await iterator.next() else {
    Issue.record("The phase stream ended before pending")
    return
  }
  if case .pending(previous: .none) = pending {
  } else {
    Issue.record("Expected initial pending without a previous value")
  }

  await work.waitForStart()
  work.succeed(with: 42)

  guard let success = await iterator.next() else {
    Issue.record("The phase stream ended before success")
    return
  }
  if case .success(let value) = success {
    #expect(value == 42)
  } else {
    Issue.record("Expected success")
  }

  #if DEBUG
  let phaseTurns = cogs.debugHistory.entries.filter {
    $0.event == .turn && ($0.name == "forecast pending" || $0.name == "forecast success")
  }
  #expect(phaseTurns.map(\.name) == ["forecast pending", "forecast success"])
  #expect(phaseTurns[0].turn != phaseTurns[1].turn)
  #endif
  withExtendedLifetime(token) {}
}
