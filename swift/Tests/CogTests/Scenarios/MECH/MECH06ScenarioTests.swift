import Cog
import CogTesting
import Testing

@MainActor private let hourlyRefreshCountCog = ManualCog<Int>(0)

@MainActor extension CogOperating {
  fileprivate func refreshCurrentLocation() {
    commit("location.hourlyRefresh") { c in
      c[hourlyRefreshCountCog] += 1
    }
  }
}

@MainActor
@Test func `MECH-06 an injected clock drives a named hourly turn`() async throws {
  let clock = TestClock()
  let (refreshEvents, refreshContinuation) = AsyncStream.makeStream(
    of: Void.self,
    bufferingPolicy: .bufferingNewest(1)
  )

  let cogs = Cogs.forTesting(
    clock: clock,
    mechanisms: [
      // The app entry point retains only `Cogs`; the timer is a mechanism
      // task whose long-running body holds its controller weakly and
      // promotes it around each unit of graph work.
      MechanismProbe(name: "Location") { m in
        m.task(name: "hourlyRefresh") { [weak m] in
          while true {
            try await clock.sleep(for: .seconds(3_600))
            guard let m else { return }
            await m.refreshCurrentLocation()
            refreshContinuation.yield()
          }
        }
      }
    ]
  )

  try await clock.waitForScheduledSleep()
  #expect(cogs.peek(hourlyRefreshCountCog) == 0)

  clock.advance(by: .seconds(3_600))
  var refreshIterator = refreshEvents.makeAsyncIterator()
  guard await refreshIterator.next() != nil else {
    Issue.record("The hourly refresh task ended before running")
    return
  }

  #expect(cogs.peek(hourlyRefreshCountCog) == 1)
  #if DEBUG
  let turns = cogs.debugHistory.entries.filter { $0.event == .turn }
  #expect(turns.map(\.name) == ["Location.location.hourlyRefresh"])
  #endif

  // "Every hour" is a loop, not a first firing: the task re-arms its sleep,
  // and the next injected hour drives a second op and a second named turn.
  try await clock.waitForScheduledSleep()
  clock.advance(by: .seconds(3_600))
  guard await refreshIterator.next() != nil else {
    Issue.record("The hourly refresh task ended before its second run")
    return
  }

  #expect(cogs.peek(hourlyRefreshCountCog) == 2)
  #if DEBUG
  let secondTurns = cogs.debugHistory.entries.filter { $0.event == .turn }
  #expect(
    secondTurns.map(\.name) == [
      "Location.location.hourlyRefresh", "Location.location.hourlyRefresh",
    ]
  )
  #endif

  try await clock.waitForScheduledSleep()
  clock.finish()
}
