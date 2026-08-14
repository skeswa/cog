import Cog
import CogTesting
import Testing
import os

private nonisolated enum AsyncColdDemandSleepOutcome {
  case cancelled
  case due
  case scheduled
}

@MainActor
private final class AsyncColdDemandControlledWork {
  let starts: AsyncStream<Int>
  let cancellations: AsyncStream<Int>

  private let startContinuation: AsyncStream<Int>.Continuation
  private let cancellationContinuation: AsyncStream<Int>.Continuation
  private let cancellationRuns = OSAllocatedUnfairLock(initialState: [Int]())
  private var nextRun = 0
  private var continuations: [Int: CheckedContinuation<Int, Never>] = [:]
  private(set) var madeRuns: [Int] = []

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
    madeRuns.append(run)
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
@Test func `ASYNC-22 ASYNC-29 one-shot peek renews one grace sleeper and recreates fresh`()
  async throws
{
  let clock = AsyncColdDemandTestClock()
  let cogs = Cogs.forTesting(clock: clock, whileObservedGrace: .seconds(10))
  let work = AsyncColdDemandControlledWork()
  var selectorRuns = 0
  let forecast = AsyncCog<Int>(default: 0, name: "forecast") { _ in
    selectorRuns += 1
    return work.makeWork()
  }
  var startIterator = work.starts.makeAsyncIterator()
  var cancellationIterator = work.cancellations.makeAsyncIterator()

  let initial = cogs.status.peek(forecast)
  if initial.kind != .pending || initial.hasSucceeded {
    Issue.record("A cold one-shot peek did not return pending without a previous value")
  }
  #expect(selectorRuns == 1)
  #expect(work.madeRuns == [0])
  #expect(await startIterator.next() == 0)
  try await clock.waitForScheduledSleep()
  #expect(clock.activeSleeperCount == 1)

  clock.advance(by: .seconds(4))
  for _ in 0..<32 {
    let repeated = cogs.status.peek(forecast)
    if repeated.kind != .pending || repeated.hasSucceeded {
      Issue.record("A repeated peek did not retain the current pending generation")
    }
    try await clock.waitForScheduledSleep()
    #expect(clock.activeSleeperCount == 1)
  }
  #expect(selectorRuns == 1)
  #expect(work.madeRuns == [0])
  #expect(clock.maximumActiveSleeperCount == 1)

  clock.advance(by: .seconds(6))
  #expect(work.cancelledRuns.isEmpty)
  #expect(clock.activeSleeperCount == 1)

  let released = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextDerivedRelease(with: released)
  clock.advance(by: .seconds(4))
  try await released.wait()
  #expect(await cancellationIterator.next() == 0)
  #expect(work.cancelledRuns == [0])
  #expect(clock.activeSleeperCount == 0)

  let lateChecked = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAsyncCompletionCheck(with: lateChecked)
  work.finish(0, with: 100)
  try await lateChecked.wait()

  #if DEBUG
  let staleResultTurns = cogs.debugHistory.entries.filter {
    $0.event == .turn && ($0.name == "forecast success" || $0.name == "forecast failure")
  }
  #expect(staleResultTurns.isEmpty)
  #endif

  let fresh = cogs.status.peek(forecast)
  if fresh.kind != .pending || fresh.hasSucceeded {
    Issue.record("A later read did not recreate fresh pending work")
  }
  #expect(selectorRuns == 2)
  #expect(work.madeRuns == [0, 1])
  #expect(await startIterator.next() == 1)
  try await clock.waitForScheduledSleep()
  #expect(clock.activeSleeperCount == 1)
  #expect(clock.maximumActiveSleeperCount == 1)

  let freshChecked = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAsyncCompletionCheck(with: freshChecked)
  work.finish(1, with: 200)
  try await freshChecked.wait()

  let completed = cogs.status.peek(forecast)
  if completed.kind == .success {
    #expect(completed.value == 200)
  } else {
    Issue.record("The recreated work did not publish its fresh result")
  }
}

@MainActor
@Test func `ASYNC-23 ASYNC-29 cold refresh is one load with one renewable grace sleeper`()
  async throws
{
  let clock = AsyncColdDemandTestClock()
  let cogs = Cogs.forTesting(clock: clock, whileObservedGrace: .seconds(10))
  let work = AsyncColdDemandControlledWork()
  var selectorRuns = 0
  let forecast = AsyncCog<Int>(default: 0, name: "forecast") { _ in
    selectorRuns += 1
    return work.makeWork()
  }
  var startIterator = work.starts.makeAsyncIterator()
  var cancellationIterator = work.cancellations.makeAsyncIterator()

  cogs.refresh(forecast)
  #expect(selectorRuns == 1)
  #expect(work.madeRuns == [0])
  #expect(work.cancelledRuns.isEmpty)
  #expect(await startIterator.next() == 0)
  try await clock.waitForScheduledSleep()
  #expect(clock.activeSleeperCount == 1)

  #if DEBUG
  let initialPendingTurns = cogs.debugHistory.entries.filter {
    $0.event == .turn && $0.name == "forecast pending"
  }
  #expect(initialPendingTurns.count == 1)
  #endif

  clock.advance(by: .seconds(4))
  for run in 1...32 {
    cogs.refresh(forecast)
    #expect(selectorRuns == run + 1)
    #expect(await cancellationIterator.next() == run - 1)
    #expect(await startIterator.next() == run)
    try await clock.waitForScheduledSleep()
    #expect(clock.activeSleeperCount == 1)
  }
  #expect(work.madeRuns == Array(0...32))
  #expect(clock.maximumActiveSleeperCount == 1)

  #if DEBUG
  let replacementPendingTurns = cogs.debugHistory.entries.filter {
    $0.event == .turn && $0.name == "forecast pending"
  }
  #expect(replacementPendingTurns.count == 33)
  #endif

  for run in 0..<32 {
    let replacedChecked = MainActorCleanupAcknowledgement()
    cogs.acknowledgeNextAsyncCompletionCheck(with: replacedChecked)
    work.finish(run, with: 100 + run)
    try await replacedChecked.wait()
  }

  clock.advance(by: .seconds(6))
  #expect(work.cancelledRuns == Array(0..<32))
  #expect(clock.activeSleeperCount == 1)

  let released = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextDerivedRelease(with: released)
  clock.advance(by: .seconds(4))
  try await released.wait()
  #expect(await cancellationIterator.next() == 32)
  #expect(work.cancelledRuns == Array(0...32))
  #expect(clock.activeSleeperCount == 0)

  let lateChecked = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAsyncCompletionCheck(with: lateChecked)
  work.finish(32, with: 200)
  try await lateChecked.wait()

  #if DEBUG
  let resultTurns = cogs.debugHistory.entries.filter {
    $0.event == .turn && ($0.name == "forecast success" || $0.name == "forecast failure")
  }
  #expect(resultTurns.isEmpty)
  #endif
}

private nonisolated final class AsyncColdDemandTestClock: Clock, @unchecked Sendable {
  private struct Sleeper {
    let id: UInt64
    let deadline: Instant
    let continuation: CheckedContinuation<Void, any Error>
  }

  private struct State {
    var now = Instant(offset: .zero)
    var sleepers: [Sleeper] = []
    var cancelledSleeperIDs: Set<UInt64> = []
    var nextSleeperID: UInt64 = 0
    var maximumActiveSleeperCount = 0
  }

  struct Instant: InstantProtocol, Hashable, Sendable {
    let offset: Swift.Duration

    static func < (lhs: Self, rhs: Self) -> Bool {
      lhs.offset < rhs.offset
    }

    func advanced(by duration: Swift.Duration) -> Self {
      Self(offset: offset + duration)
    }

    func duration(to other: Self) -> Swift.Duration {
      other.offset - offset
    }
  }

  typealias Duration = Swift.Duration

  private let state = OSAllocatedUnfairLock(initialState: State())
  private let scheduledEvents: AsyncStream<Void>
  private let scheduledContinuation: AsyncStream<Void>.Continuation

  init() {
    (scheduledEvents, scheduledContinuation) = AsyncStream.makeStream(
      bufferingPolicy: .bufferingNewest(1)
    )
  }

  var now: Instant {
    state.withLock { $0.now }
  }

  var minimumResolution: Swift.Duration { .nanoseconds(1) }

  var activeSleeperCount: Int {
    state.withLock { $0.sleepers.count }
  }

  var maximumActiveSleeperCount: Int {
    state.withLock { $0.maximumActiveSleeperCount }
  }

  func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {
    try Task.checkCancellation()
    let sleeperID = state.withLock { state in
      let sleeperID = state.nextSleeperID
      state.nextSleeperID += 1
      return sleeperID
    }

    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        let outcome = state.withLock { state in
          if state.cancelledSleeperIDs.remove(sleeperID) != nil || Task.isCancelled {
            return AsyncColdDemandSleepOutcome.cancelled
          }
          guard deadline > state.now else { return .due }
          state.sleepers.append(
            Sleeper(id: sleeperID, deadline: deadline, continuation: continuation)
          )
          state.maximumActiveSleeperCount = max(
            state.maximumActiveSleeperCount,
            state.sleepers.count
          )
          return .scheduled
        }

        switch outcome {
        case .cancelled:
          continuation.resume(throwing: CancellationError())
        case .due:
          continuation.resume()
        case .scheduled:
          scheduledContinuation.yield()
        }
      }
    } onCancel: {
      let continuation: CheckedContinuation<Void, any Error>? = state.withLock { state in
        guard let index = state.sleepers.firstIndex(where: { $0.id == sleeperID }) else {
          state.cancelledSleeperIDs.insert(sleeperID)
          return nil
        }
        return state.sleepers.remove(at: index).continuation
      }
      continuation?.resume(throwing: CancellationError())
    }
  }

  func waitForScheduledSleep() async throws {
    var iterator = scheduledEvents.makeAsyncIterator()
    guard await iterator.next() != nil else {
      throw CancellationError()
    }
  }

  func advance(by duration: Swift.Duration) {
    let due = state.withLock { state in
      state.now = state.now.advanced(by: duration)
      var due: [CheckedContinuation<Void, any Error>] = []
      state.sleepers.removeAll { sleeper in
        guard sleeper.deadline <= state.now else { return false }
        due.append(sleeper.continuation)
        return true
      }
      return due
    }

    for continuation in due {
      continuation.resume()
    }
  }
}
