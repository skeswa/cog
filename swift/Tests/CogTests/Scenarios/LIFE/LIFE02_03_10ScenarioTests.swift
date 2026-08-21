import Cog
import CogTesting
import Testing
import os

private nonisolated enum AutomaticLifetimeSleepOutcome {
  case cancelled
  case due
  case scheduled
}

@MainActor
@Test func `LIFE-02 an unobserved automatic cog is released after injected grace`() async throws {
  let clock = AutomaticLifetimeTestClock()
  let watcherAlive = ManualCog<Bool>(true)
  var selectorRuns = 0
  let automatic = Cog<Int> { _ in
    selectorRuns += 1
    return 10
  }

  let (cogs, m) = probedContext(
    clock: clock,
    whileObservedGrace: .seconds(10)
  )
  m.whenever(watcherAlive) { s in
    s.run { c in _ = c[automatic] }
  }
  #expect(selectorRuns == 1)

  let released = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAutomaticRelease(with: released)
  // Lowering the gate tears the watching reaction down: the last watcher
  // leaves and grace begins.
  cogs.turn(watcherAlive, to: false)
  try await clock.waitForScheduledSleep()
  clock.advance(by: .seconds(10))
  try await released.wait()

  #expect(released.hasBeenAcknowledged)
  #expect(cogs.peek(automatic) == 10)
  #expect(selectorRuns == 2)
}

@MainActor
@Test func `LIFE-03 the same value reference recreates from current state after release`()
  async throws
{
  let clock = AutomaticLifetimeTestClock()
  let watcherAlive = ManualCog<Bool>(true)
  let source = ManualCog<Int>(1)
  var previousValues: [Int?] = []
  let automatic = Cog<Int> { c in
    previousValues.append(c.curr)
    return c[source]
  }

  let (cogs, m) = probedContext(
    clock: clock,
    whileObservedGrace: .seconds(10)
  )
  m.whenever(watcherAlive) { s in
    s.run { c in _ = c[automatic] }
  }
  #expect(previousValues == [nil])

  let released = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAutomaticRelease(with: released)
  cogs.turn(watcherAlive, to: false)
  cogs.turn { c in c[source] = 2 }
  try await clock.waitForScheduledSleep()
  clock.advance(by: .seconds(10))
  try await released.wait()

  #expect(cogs.peek(automatic) == 2)
  #expect(previousValues == [nil, nil])
}

@MainActor
@Test func `LIFE-10 one-shot automatic peek renews grace then releases and recreates`()
  async throws
{
  let clock = AutomaticLifetimeTestClock()
  let cogs = Cogs.forTesting(
    clock: clock,
    whileObservedGrace: .seconds(10)
  )
  let source = ManualCog<Int>(1)
  var previousValues: [Int?] = []
  let automatic = Cog<Int> { c in
    previousValues.append(c.curr)
    return c[source]
  }

  #expect(cogs.peek(automatic) == 1)
  try await clock.waitForScheduledSleep()
  #expect(clock.activeSleeperCount == 1)

  clock.advance(by: .seconds(4))
  for _ in 0..<32 {
    #expect(cogs.peek(automatic) == 1)
    try await clock.waitForScheduledSleep()
    #expect(clock.activeSleeperCount == 1)
  }
  #expect(previousValues == [nil])
  #expect(clock.maximumActiveSleeperCount == 1)

  clock.advance(by: .seconds(6))
  #expect(clock.activeSleeperCount == 1)

  let released = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAutomaticRelease(with: released)
  clock.advance(by: .seconds(4))
  try await released.wait()
  #expect(clock.activeSleeperCount == 0)

  cogs.turn { c in c[source] = 2 }
  #expect(cogs.peek(automatic) == 2)
  #expect(previousValues == [nil, nil])
}

nonisolated final class AutomaticLifetimeTestClock: Clock, @unchecked Sendable {
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

  func sleep(
    until deadline: Instant,
    tolerance: Swift.Duration?
  ) async throws {
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
            return AutomaticLifetimeSleepOutcome.cancelled
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
