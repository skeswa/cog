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

  // The high-water mark lasts for the clock's lifetime. It distinguishes two
  // timers that once coexisted from one timer renewed twice.
  #expect(clock.maximumActiveSleeperCount == 2)
}
