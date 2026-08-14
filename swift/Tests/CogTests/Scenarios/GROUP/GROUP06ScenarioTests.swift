import Cog
import CogTesting
import Testing

@MainActor private let hourlyRefreshCount = ManualCog<Int>(0)

@MainActor extension Cogs {
  fileprivate func refreshCurrentLocation() {
    commit("location.hourlyRefresh") { c in
      c[hourlyRefreshCount] += 1
    }
  }
}

@MainActor private struct HourlyEffects {
  let clock: TestClock
  let refreshes: AsyncStream<Void>.Continuation

  func install(in cogs: Cogs) {
    cogs.effects.task(name: "location.hourlyRefresh.timer") {
      while true {
        try await clock.sleep(for: .seconds(3_600))
        await cogs.refreshCurrentLocation()
        refreshes.yield()
      }
    }
  }
}

@MainActor
@Test func `GROUP-06 an injected clock drives a named hourly turn`() async throws {
  let clock = TestClock()
  let cogs = Cogs.forTesting(clock: clock)
  let (refreshEvents, refreshContinuation) = AsyncStream.makeStream(
    of: Void.self,
    bufferingPolicy: .bufferingNewest(1)
  )
  HourlyEffects(clock: clock, refreshes: refreshContinuation).install(in: cogs)

  try await clock.waitForScheduledSleep()
  #expect(cogs.peek(hourlyRefreshCount) == 0)

  clock.advance(by: .seconds(3_600))
  var refreshIterator = refreshEvents.makeAsyncIterator()
  guard await refreshIterator.next() != nil else {
    Issue.record("The hourly refresh task ended before running")
    return
  }

  #expect(cogs.peek(hourlyRefreshCount) == 1)
  #if DEBUG
  let turns = cogs.debugHistory.entries.filter { $0.event == .turn }
  #expect(turns.map(\.name) == ["location.hourlyRefresh"])
  #endif

  // "Every hour" is a loop, not a first firing: the task re-arms its sleep,
  // and the next injected hour drives a second op and a second named turn.
  try await clock.waitForScheduledSleep()
  clock.advance(by: .seconds(3_600))
  guard await refreshIterator.next() != nil else {
    Issue.record("The hourly refresh task ended before its second run")
    return
  }

  #expect(cogs.peek(hourlyRefreshCount) == 2)
  #if DEBUG
  let secondTurns = cogs.debugHistory.entries.filter { $0.event == .turn }
  #expect(secondTurns.map(\.name) == ["location.hourlyRefresh", "location.hourlyRefresh"])
  #endif

  try await clock.waitForScheduledSleep()
  clock.finish()
}
