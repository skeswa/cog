import Cog
import CogTesting
import Testing
import os

@MainActor private let hourlyRefreshCount = ManualCog<Int>(0)

@MainActor private struct HourlyEffects {
  let clock: HourlyTestClock
  let refreshes: AsyncStream<Void>.Continuation

  func install(in cogs: Cogtext) -> EffectGroup {
    let group = EffectGroup()
    group.task(name: "location.hourlyRefresh.timer") {
      while true {
        try await clock.sleep(for: .seconds(3_600))
        cogs.commit("location.hourlyRefresh") { writer in
          writer[hourlyRefreshCount] += 1
        }
        refreshes.yield()
      }
    }
    return group
  }
}

@MainActor
@Test func `GROUP-06 an injected clock drives a named hourly turn`() async throws {
  let clock = HourlyTestClock()
  let cogs = Cogtext.forTesting(clock: clock)
  let (refreshEvents, refreshContinuation) = AsyncStream.makeStream(
    of: Void.self,
    bufferingPolicy: .bufferingNewest(1)
  )
  let group = HourlyEffects(clock: clock, refreshes: refreshContinuation).install(in: cogs)

  try await clock.waitForScheduledSleep()
  #expect(cogs.read(hourlyRefreshCount) == 0)

  clock.advance(by: .seconds(3_600))
  var refreshIterator = refreshEvents.makeAsyncIterator()
  guard await refreshIterator.next() != nil else {
    Issue.record("The hourly refresh task ended before running")
    return
  }

  #expect(cogs.read(hourlyRefreshCount) == 1)
  #if DEBUG
  let turns = cogs.debugHistory.entries.filter { $0.event == .turn }
  #expect(turns.map(\.name) == ["location.hourlyRefresh"])
  #endif

  try await clock.waitForScheduledSleep()
  group.cancel()
}

private nonisolated final class HourlyTestClock: Clock, @unchecked Sendable {
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

  private let nowState = OSAllocatedUnfairLock(initialState: Instant(offset: .zero))
  private let ticks: AsyncStream<Void>
  private let tickContinuation: AsyncStream<Void>.Continuation
  private let scheduledEvents: AsyncStream<Void>
  private let scheduledContinuation: AsyncStream<Void>.Continuation

  init() {
    (ticks, tickContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    (scheduledEvents, scheduledContinuation) = AsyncStream.makeStream(
      bufferingPolicy: .bufferingNewest(1)
    )
  }

  var now: Instant {
    nowState.withLock { $0 }
  }

  var minimumResolution: Swift.Duration { .nanoseconds(1) }

  func sleep(
    until deadline: Instant,
    tolerance: Swift.Duration?
  ) async throws {
    try Task.checkCancellation()
    while now < deadline {
      scheduledContinuation.yield()
      var iterator = ticks.makeAsyncIterator()
      guard await iterator.next() != nil else {
        throw CancellationError()
      }
      try Task.checkCancellation()
    }
  }

  func waitForScheduledSleep() async throws {
    var iterator = scheduledEvents.makeAsyncIterator()
    guard await iterator.next() != nil else {
      throw CancellationError()
    }
  }

  func advance(by duration: Swift.Duration) {
    nowState.withLock { instant in
      instant = instant.advanced(by: duration)
    }
    tickContinuation.yield()
  }
}
