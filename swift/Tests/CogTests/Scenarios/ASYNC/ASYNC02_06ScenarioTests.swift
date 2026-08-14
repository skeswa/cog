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
  let cogs = Cogs.forTesting()
  let work = Async02ControlledWork()
  let forecast = AsyncCog<Int>(default: 0, name: "forecast") { _ in
    .run { try await work.run() }
  }
  let refresh = cogs.refresh(forecast)
  let (statuses, continuation) = AsyncStream.makeStream(of: CogStatus<Int>.self)
  let token = cogs.run { c in continuation.yield(c.status[forecast]) }
  var iterator = statuses.makeAsyncIterator()

  guard let pending = await iterator.next() else {
    Issue.record("The status stream ended before pending")
    return
  }
  if pending.kind != .pending || pending.hasSucceeded {
    Issue.record("Expected initial pending without a previous value")
  }

  await work.waitForStart()
  work.fail(with: Async02Error.offline)

  guard let failure = await iterator.next() else {
    Issue.record("The status stream ended before failure")
    return
  }
  if failure.kind == .failure, !failure.hasSucceeded {
    #expect(failure.error as? Async02Error == .offline)
  } else {
    Issue.record("Expected failure without a previous value")
  }
  switch await refresh.outcome {
  case .failure(let error):
    #expect(error as? Async02Error == .offline)
  default:
    Issue.record("The exact refresh handle did not retain its failure")
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
  let cogs = Cogs.forTesting()
  let work = Async02ControlledWork()
  let forecast = AsyncCog<Int>(default: 0, name: "forecast") { _ in
    .run { try await work.run() }
  }
  let (statuses, continuation) = AsyncStream.makeStream(of: CogStatus<Int>.self)
  let token = cogs.run { c in continuation.yield(c.status[forecast]) }
  var iterator = statuses.makeAsyncIterator()

  guard let pending = await iterator.next() else {
    Issue.record("The status stream ended before pending")
    return
  }
  if pending.kind != .pending || pending.hasSucceeded {
    Issue.record("Expected initial pending without a previous value")
  }

  await work.waitForStart()
  work.succeed(with: 42)

  guard let success = await iterator.next() else {
    Issue.record("The status stream ended before success")
    return
  }
  if success.kind == .success {
    #expect(success.value == 42)
  } else {
    Issue.record("Expected success")
  }

  #if DEBUG
  let statusTurns = cogs.debugHistory.entries.filter {
    $0.event == .turn && ($0.name == "forecast pending" || $0.name == "forecast success")
  }
  #expect(statusTurns.map(\.name) == ["forecast pending", "forecast success"])
  #expect(statusTurns[0].turn != statusTurns[1].turn)
  #endif
  withExtendedLifetime(token) {}
}
