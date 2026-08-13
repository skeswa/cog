import CogTesting
import Testing

@testable import Cog

private nonisolated enum CogTestingClockProbeError: Error, Equatable {
  case slept(marker: Int)
}

private nonisolated struct CogTestingClockProbe: Clock {
  typealias Instant = ContinuousClock.Instant
  typealias Duration = Swift.Duration

  let marker: Int

  var now: Instant { ContinuousClock().now }
  var minimumResolution: Duration { .nanoseconds(1) }

  func sleep(until _: Instant, tolerance _: Duration?) async throws {
    throw CogTestingClockProbeError.slept(marker: marker)
  }
}

@MainActor
@Test func `CogTestingClockInfrastructure injects one clock into each testing context`() async {
  let first = Cogs.forTesting(clock: CogTestingClockProbe(marker: 1))
  let second = Cogs.forTesting(clock: CogTestingClockProbe(marker: 2))

  await #expect(throws: CogTestingClockProbeError.slept(marker: 1)) {
    try await first.clock.sleep(for: .zero)
  }
  await #expect(throws: CogTestingClockProbeError.slept(marker: 2)) {
    try await second.clock.sleep(for: .zero)
  }
}

@Test func `CogTestingClockInfrastructure TestClock resumes concurrent sleeps by deadline`()
  async throws
{
  let clock = TestClock()
  let (events, continuation) = AsyncStream.makeStream(of: Int.self)
  var iterator = events.makeAsyncIterator()

  let later = Task {
    try await clock.sleep(for: .seconds(10))
    continuation.yield(10)
  }
  let sooner = Task {
    try await clock.sleep(for: .seconds(5))
    continuation.yield(5)
  }

  try await clock.waitForScheduledSleep()
  try await clock.waitForScheduledSleep()
  clock.advance(by: .seconds(5))
  #expect(await iterator.next() == 5)
  clock.advance(by: .seconds(5))
  #expect(await iterator.next() == 10)

  try await sooner.value
  try await later.value
  clock.finish()
}
