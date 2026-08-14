import Cog
import CogTesting
import Testing

@MainActor
private final class Async13ControlledWork {
  let starts: AsyncStream<Int>
  let cancellations: AsyncStream<Int>

  private let startContinuation: AsyncStream<Int>.Continuation
  private let cancellationContinuation: AsyncStream<Int>.Continuation
  private var nextRun = 0
  private var continuations: [Int: CheckedContinuation<Int, Never>] = [:]

  init() {
    (starts, startContinuation) = AsyncStream.makeStream(of: Int.self)
    (cancellations, cancellationContinuation) = AsyncStream.makeStream(of: Int.self)
  }

  func makeWork() -> Work<Int> {
    let run = nextRun
    nextRun += 1
    let startContinuation = startContinuation
    let cancellationContinuation = cancellationContinuation

    return .run {
      await withTaskCancellationHandler {
        startContinuation.yield(run)
        return await withCheckedContinuation { self.continuations[run] = $0 }
      } onCancel: {
        cancellationContinuation.yield(run)
      }
    }
  }

  func finish(_ run: Int, with value: Int) {
    continuations.removeValue(forKey: run)?.resume(returning: value)
  }
}

@MainActor
@Test func `ASYNC-13 release cancels pending work and rejects its late result`() async throws {
  let clock = TestClock()
  let (cogs, m) = probedContext(clock: clock, whileObservedGrace: .seconds(10))
  let work = Async13ControlledWork()
  let forecast = AsyncCog<Int>(default: 0, name: "forecast") { _ in work.makeWork() }
  let watcherAlive = ManualCog<Bool>(true)
  let refresh = cogs.refresh(forecast)
  m.whenever(watcherAlive) { s in
    s.run { c in _ = c[forecast] }
  }
  var startIterator = work.starts.makeAsyncIterator()
  var cancellationIterator = work.cancellations.makeAsyncIterator()

  #expect(await startIterator.next() == 0)
  let released = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextDerivedRelease(with: released)
  cogs.commit(watcherAlive, to: false)
  try await clock.waitForScheduledSleep()
  try await clock.waitForScheduledSleep()
  clock.advance(by: .seconds(10))
  try await released.wait()
  #expect(await cancellationIterator.next() == 0)
  if case .released = await refresh.outcome {
  } else {
    Issue.record("Lifetime release did not resolve the exact refresh handle")
  }

  let lateChecked = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAsyncCompletionCheck(with: lateChecked)
  work.finish(0, with: 100)
  try await lateChecked.wait()

  #if DEBUG
  let resultTurns = cogs.debugHistory.entries.filter {
    $0.event == .turn && ($0.name == "forecast success" || $0.name == "forecast failure")
  }
  #expect(resultTurns.isEmpty)
  #endif
}

@MainActor
@Test func `ASYNC-14 reading after release starts fresh unpolluted work`() async throws {
  let clock = TestClock()
  let (cogs, m) = probedContext(clock: clock, whileObservedGrace: .seconds(10))
  let work = Async13ControlledWork()
  let forecast = AsyncCog<Int>(default: 0, name: "forecast") { _ in work.makeWork() }
  let firstWatcherAlive = ManualCog<Bool>(true)
  m.whenever(firstWatcherAlive) { s in
    s.run { c in _ = c[forecast] }
  }
  var startIterator = work.starts.makeAsyncIterator()
  var cancellationIterator = work.cancellations.makeAsyncIterator()

  #expect(await startIterator.next() == 0)
  let released = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextDerivedRelease(with: released)
  cogs.commit(firstWatcherAlive, to: false)
  try await clock.waitForScheduledSleep()
  clock.advance(by: .seconds(10))
  try await released.wait()
  #expect(await cancellationIterator.next() == 0)

  let lateChecked = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAsyncCompletionCheck(with: lateChecked)
  work.finish(0, with: 100)
  try await lateChecked.wait()

  let (statuses, continuation) = AsyncStream.makeStream(of: CogStatus<Int>.self)
  m.run { c in continuation.yield(c.status[forecast]) }
  var statusIterator = statuses.makeAsyncIterator()
  guard let freshPending = await statusIterator.next() else {
    Issue.record("The recreated status stream ended before pending")
    return
  }
  if freshPending.kind != .pending || freshPending.hasSucceeded {
    Issue.record("Recreated work did not start from fresh pending state")
  }
  #expect(await startIterator.next() == 1)

  work.finish(1, with: 200)
  guard let freshSuccess = await statusIterator.next() else {
    Issue.record("The recreated status stream ended before success")
    return
  }
  if freshSuccess.kind == .success {
    #expect(freshSuccess.value == 200)
  } else {
    Issue.record("Expected only the recreated work's result")
  }
}
