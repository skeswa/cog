import Cog
import CogTesting
import Testing
import os

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
@Test func `ASYNC-22 one-shot peek starts once renews grace and recreates fresh`() async throws {
  let clock = AsyncColdDemandTestClock()
  let cogs = Cogtext.forTesting(clock: clock, whileObservedGrace: .seconds(10))
  let work = AsyncColdDemandControlledWork()
  var selectorRuns = 0
  let forecast = AsyncCog<Int>(name: "forecast") { _ in
    selectorRuns += 1
    return work.makeWork()
  }
  var startIterator = work.starts.makeAsyncIterator()
  var cancellationIterator = work.cancellations.makeAsyncIterator()

  let initial = cogs.peek(forecast)
  if case .pending(previous: .none) = initial {
  } else {
    Issue.record("A cold one-shot peek did not return pending without a previous value")
  }
  #expect(selectorRuns == 1)
  #expect(work.madeRuns == [0])
  #expect(await startIterator.next() == 0)
  try await clock.waitForScheduledSleep()

  clock.advance(by: .seconds(4))
  let repeated = cogs.peek(forecast)
  if case .pending(previous: .none) = repeated {
  } else {
    Issue.record("A repeated peek did not retain the current pending generation")
  }
  #expect(selectorRuns == 1)
  #expect(work.madeRuns == [0])
  try await clock.waitForScheduledSleep()

  let staleGraceChecked = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextDerivedReleaseCheck(with: staleGraceChecked)
  clock.advance(by: .seconds(6))
  try await staleGraceChecked.wait()
  #expect(work.cancelledRuns.isEmpty)

  let released = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextDerivedRelease(with: released)
  clock.advance(by: .seconds(4))
  try await released.wait()
  #expect(await cancellationIterator.next() == 0)
  #expect(work.cancelledRuns == [0])

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

  let fresh = cogs.peek(forecast)
  if case .pending(previous: .none) = fresh {
  } else {
    Issue.record("A later read did not recreate fresh pending work")
  }
  #expect(selectorRuns == 2)
  #expect(work.madeRuns == [0, 1])
  #expect(await startIterator.next() == 1)

  let freshChecked = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAsyncCompletionCheck(with: freshChecked)
  work.finish(1, with: 200)
  try await freshChecked.wait()

  if case .success(let value) = cogs.peek(forecast) {
    #expect(value == 200)
  } else {
    Issue.record("The recreated work did not publish its fresh result")
  }
}

@MainActor
@Test func `ASYNC-23 cold refresh is one load and follows renewable grace`() async throws {
  let clock = AsyncColdDemandTestClock()
  let cogs = Cogtext.forTesting(clock: clock, whileObservedGrace: .seconds(10))
  let work = AsyncColdDemandControlledWork()
  var selectorRuns = 0
  let forecast = AsyncCog<Int>(name: "forecast") { _ in
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

  #if DEBUG
  let initialPendingTurns = cogs.debugHistory.entries.filter {
    $0.event == .turn && $0.name == "forecast pending"
  }
  #expect(initialPendingTurns.count == 1)
  #endif

  clock.advance(by: .seconds(4))
  cogs.refresh(forecast)
  #expect(selectorRuns == 2)
  #expect(work.madeRuns == [0, 1])
  #expect(await cancellationIterator.next() == 0)
  #expect(await startIterator.next() == 1)
  try await clock.waitForScheduledSleep()

  #if DEBUG
  let replacementPendingTurns = cogs.debugHistory.entries.filter {
    $0.event == .turn && $0.name == "forecast pending"
  }
  #expect(replacementPendingTurns.count == 2)
  #endif

  let replacedChecked = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAsyncCompletionCheck(with: replacedChecked)
  work.finish(0, with: 100)
  try await replacedChecked.wait()

  let staleGraceChecked = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextDerivedReleaseCheck(with: staleGraceChecked)
  clock.advance(by: .seconds(6))
  try await staleGraceChecked.wait()
  #expect(work.cancelledRuns == [0])

  let released = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextDerivedRelease(with: released)
  clock.advance(by: .seconds(4))
  try await released.wait()
  #expect(await cancellationIterator.next() == 1)
  #expect(work.cancelledRuns == [0, 1])

  let lateChecked = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAsyncCompletionCheck(with: lateChecked)
  work.finish(1, with: 200)
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
    let deadline: Instant
    let continuation: CheckedContinuation<Void, any Error>
  }

  private struct State {
    var now = Instant(offset: .zero)
    var sleepers: [Sleeper] = []
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

  func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {
    try Task.checkCancellation()
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      let isAlreadyDue = state.withLock { state in
        guard deadline > state.now else { return true }
        state.sleepers.append(Sleeper(deadline: deadline, continuation: continuation))
        return false
      }

      if isAlreadyDue {
        continuation.resume()
      } else {
        scheduledContinuation.yield()
      }
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
