import Cog
import CogTesting
import Testing
import os

@MainActor
@Test func `LIFE-02 an unobserved derived cog is released after injected grace`() async throws {
  let clock = DerivedLifetimeTestClock()
  let cogs = Cogtext.forTesting(
    clock: clock,
    whileObservedGrace: .seconds(10)
  )
  var selectorRuns = 0
  let derived = Cog<Int> { _ in
    selectorRuns += 1
    return 10
  }

  let token = cogs.run { c in _ = c.get(derived) }
  #expect(selectorRuns == 1)

  let released = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextDerivedRelease(with: released)
  token.cancel()
  try await clock.waitForScheduledSleep()
  clock.advance(by: .seconds(10))
  try await released.wait()

  #expect(released.hasBeenAcknowledged)
  #expect(cogs.read(derived) == 10)
  #expect(selectorRuns == 2)
  withExtendedLifetime(token) {}
}

@MainActor
@Test func `LIFE-03 the same value reference recreates from current state after release`()
  async throws
{
  let clock = DerivedLifetimeTestClock()
  let cogs = Cogtext.forTesting(
    clock: clock,
    whileObservedGrace: .seconds(10)
  )
  let source = ManualCog<Int>(1)
  var previousValues: [Int?] = []
  let derived = Cog<Int> { c in
    previousValues.append(c.curr)
    return c.get(source)
  }

  let token = cogs.run { c in _ = c.get(derived) }
  #expect(previousValues == [nil])

  let released = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextDerivedRelease(with: released)
  token.cancel()
  cogs.commit { w in w[source] = 2 }
  try await clock.waitForScheduledSleep()
  clock.advance(by: .seconds(10))
  try await released.wait()

  #expect(cogs.read(derived) == 2)
  #expect(previousValues == [nil, nil])
  withExtendedLifetime(token) {}
}

nonisolated final class DerivedLifetimeTestClock: Clock, @unchecked Sendable {
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

  func sleep(
    until deadline: Instant,
    tolerance: Swift.Duration?
  ) async throws {
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
