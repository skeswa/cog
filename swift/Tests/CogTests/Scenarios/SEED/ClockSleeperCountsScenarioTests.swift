import CogTesting
import Testing

@MainActor
@Test func `SEED-12 TestClock counts active sleepers and keeps their high-water mark`()
  async throws
{
  let clock = TestClock()
  #expect(clock.activeSleeperCount == 0)
  #expect(clock.maximumActiveSleeperCount == 0)

  let first = Task {
    try await clock.sleep(until: clock.now.advanced(by: .seconds(5)), tolerance: nil)
  }
  try await clock.waitForScheduledSleep()
  #expect(clock.activeSleeperCount == 1)

  let second = Task {
    try await clock.sleep(until: clock.now.advanced(by: .seconds(10)), tolerance: nil)
  }
  try await clock.waitForScheduledSleep()
  #expect(clock.activeSleeperCount == 2)
  #expect(clock.maximumActiveSleeperCount == 2)

  clock.advance(by: .seconds(5))
  try await first.value
  #expect(clock.activeSleeperCount == 1)

  clock.advance(by: .seconds(5))
  try await second.value
  #expect(clock.activeSleeperCount == 0)

  // The high-water mark is the clock-lifetime maximum, so it survives the
  // sleepers it counted — the difference that separates "two timers once
  // existed" from "one timer, twice renewed".
  #expect(clock.maximumActiveSleeperCount == 2)
}
