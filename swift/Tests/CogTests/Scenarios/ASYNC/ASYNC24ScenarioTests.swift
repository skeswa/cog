import Cog
import CogTesting
import Testing

@MainActor
private final class Async24ControlledWork {
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

  func succeed(_ request: Int, with value: Int) {
    guard let continuation = continuations.removeValue(forKey: request) else {
      fatalError("Async request \(request) completed before its work started.")
    }
    continuation.resume(returning: value)
  }
}

@MainActor
@Test func `ASYNC-24 an invalidated cold run cannot clear its dependency change`() async throws {
  let clock = AutomaticLifetimeTestClock()
  let (cogs, m) = probedContext(clock: clock, whileObservedGrace: .seconds(10))
  let request = ManualCog<Int>(0)
  let work = Async24ControlledWork()
  let forecast = AsyncCog<Int>(default: 0, name: "forecast") { c in
    let selectedRequest = c[request]
    return .run { await work.run(for: selectedRequest) }
  }
  let initialWatcherAlive = ManualCog<Bool>(true)
  let (initialStatuses, initialContinuation) = AsyncStream.makeStream(of: CogStatus<Int>.self)
  m.whenever(initialWatcherAlive) { s in
    s.run { c in initialContinuation.yield(c.status[forecast]) }
  }
  var initialStatusIterator = initialStatuses.makeAsyncIterator()
  var startIterator = work.starts.makeAsyncIterator()

  guard let initialPending = await initialStatusIterator.next(),
    initialPending.kind == .pending, !initialPending.hasSucceeded
  else {
    Issue.record("Expected initial pending without a previous value")
    return
  }
  #expect(await startIterator.next() == 0)

  cogs.turn(initialWatcherAlive, to: false)
  try await clock.waitForScheduledSleep()
  cogs.turn("change request while cold") { c in c[request] = 1 }

  let staleChecked = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAsyncCompletionCheck(with: staleChecked)
  work.succeed(0, with: 100)
  try await staleChecked.wait()

  let (returningStatuses, returningContinuation) = AsyncStream.makeStream(of: CogStatus<Int>.self)
  m.run { c in returningContinuation.yield(c.status[forecast]) }
  var returningStatusIterator = returningStatuses.makeAsyncIterator()

  guard let returningPending = await returningStatusIterator.next(),
    returningPending.kind == .pending, !returningPending.hasSucceeded
  else {
    Issue.record("A returning consumer observed the invalidated run's result")
    return
  }
  #expect(await startIterator.next() == 1)

  work.succeed(1, with: 200)
  guard let returningSuccess = await returningStatusIterator.next(),
    returningSuccess.kind == .success, returningSuccess.value == 200
  else {
    Issue.record("Expected only work selected from the newest source value to turn")
    return
  }

}
