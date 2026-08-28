import Cog
import CogTesting
import Testing
import os

@MainActor
private final class Async25ControlledWork {
  let starts: AsyncStream<Int>
  let cancellations: AsyncStream<Int>

  private let startContinuation: AsyncStream<Int>.Continuation
  private let cancellationContinuation: AsyncStream<Int>.Continuation
  private let cancellationRuns = OSAllocatedUnfairLock(initialState: [Int]())
  private var nextRun = 0
  private var continuations: [Int: CheckedContinuation<Int, Never>] = [:]

  init() {
    (starts, startContinuation) = AsyncStream.makeStream(of: Int.self)
    (cancellations, cancellationContinuation) = AsyncStream.makeStream(of: Int.self)
  }

  var cancelledRuns: [Int] {
    cancellationRuns.withLock { $0 }
  }

  func makeWork() -> Work<Int> {
    let run = nextRun
    nextRun += 1
    let startContinuation = startContinuation
    let cancellationContinuation = cancellationContinuation
    let cancellationRuns = cancellationRuns

    return .run {
      await withTaskCancellationHandler {
        startContinuation.yield(run)
        return await withCheckedContinuation { self.continuations[run] = $0 }
      } onCancel: {
        cancellationRuns.withLock { $0.append(run) }
        cancellationContinuation.yield(run)
      }
    }
  }

  func finish(_ run: Int, with value: Int) {
    continuations.removeValue(forKey: run)?.resume(returning: value)
  }
}

@MainActor
@Test func `ASYNC-25 value-only demand releases its pending chain after one grace`() async throws {
  let clock = TestClock()
  let (cogs, m) = Cogs.forTestingWithController(clock: clock, whileObservedGrace: .seconds(10))
  let work = Async25ControlledWork()
  var selectorRuns = 0
  let forecast = Cog<Int>.Async(default: 0, name: "forecast") { _ in
    selectorRuns += 1
    return work.makeWork()
  }
  var startIterator = work.starts.makeAsyncIterator()
  var cancellationIterator = work.cancellations.makeAsyncIterator()

  let firstWatcherAlive = Cog<Bool>.Manual { true }
  m.whenever(firstWatcherAlive) { s in
    s.run { c in _ = c[forecast] }
  }
  #expect(selectorRuns == 1)
  #expect(await startIterator.next() == 0)

  let released = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAutomaticRelease(with: released)
  cogs.turn(firstWatcherAlive, to: false)
  try await clock.waitForScheduledSleep()
  clock.advance(by: .seconds(10))
  try await released.wait()

  guard work.cancelledRuns == [0] else {
    Issue.record("The async dependency survived the projection's grace deadline")
    work.finish(0, with: 100)
    return
  }
  #expect(await cancellationIterator.next() == 0)

  m.run { c in _ = c[forecast] }
  guard selectorRuns == 2 else {
    Issue.record("The value projection and async dependency were not both recreated")
    work.finish(0, with: 100)
    return
  }
  #expect(await startIterator.next() == 1)

  let staleChecked = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAsyncCompletionCheck(with: staleChecked)
  work.finish(0, with: 100)
  try await staleChecked.wait()

  #if DEBUG
  let staleResultTurns = cogs.debugHistory.entries.filter {
    $0.event == .turn && ($0.name == "forecast success" || $0.name == "forecast failure")
  }
  #expect(staleResultTurns.isEmpty)
  #endif

  let freshChecked = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAsyncCompletionCheck(with: freshChecked)
  work.finish(1, with: 200)
  try await freshChecked.wait()
}
