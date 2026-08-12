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
  let first = Cogtext.forTesting(clock: CogTestingClockProbe(marker: 1))
  let second = Cogtext.forTesting(clock: CogTestingClockProbe(marker: 2))

  await #expect(throws: CogTestingClockProbeError.slept(marker: 1)) {
    try await first.clock.sleep(for: .zero)
  }
  await #expect(throws: CogTestingClockProbeError.slept(marker: 2)) {
    try await second.clock.sleep(for: .zero)
  }
}
