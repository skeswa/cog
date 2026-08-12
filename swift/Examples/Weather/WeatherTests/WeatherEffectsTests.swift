#if DEBUG

import Cog
import CogTesting
import Testing
import os

@MainActor
@Test func niceWeatherEffectSkipsInstallationAndAlertsOnFalseToTrueTransitions() {
  let cogs = Cogtext.forTesting()
  var alerts: [String] = []
  let notifier = Notifier { alerts.append($0) }

  cogs.seedCurrentZip(.newYork)
  cogs.seedWeather(
    Weather(kind: .cloudy, temperatureF: 60),
    heatAdvisory: false,
    zip: .newYork
  )

  let group = WeatherEffects(notifier: notifier, initialZipCodes: []).install(in: cogs)
  #expect(alerts.isEmpty)

  cogs.stubWeather(
    Weather(kind: .clear, temperatureF: 75),
    heatAdvisory: false,
    zip: .newYork
  )
  #expect(alerts == ["It is nice outside!"])

  cogs.stubWeather(
    Weather(kind: .partlyCloudy, temperatureF: 80),
    heatAdvisory: false,
    zip: .newYork
  )
  #expect(alerts == ["It is nice outside!"])

  cogs.stubWeather(
    Weather(kind: .rain, temperatureF: 55),
    heatAdvisory: false,
    zip: .newYork
  )
  cogs.stubWeather(
    Weather(kind: .clear, temperatureF: 70),
    heatAdvisory: false,
    zip: .newYork
  )
  #expect(alerts == ["It is nice outside!", "It is nice outside!"])

  let effectNames = cogs.debugHistory.entries
    .filter { $0.event == .effect }
    .map(\.name)
  #expect(effectNames.contains("weather.niceAlert"))

  group.cancel()
}

@MainActor
@Test func injectedClockRunsTheHourlyWeatherOperation() async throws {
  let clock = WeatherTestClock()
  let cogs = Cogtext.forTesting()
  let refreshedWeather = Weather(kind: .clear, temperatureF: 75)
  let service = WeatherService(
    weather: { zip in
      #expect(zip == .newYork)
      return refreshedWeather
    },
    advisories: { zip in
      #expect(zip == .newYork)
      return []
    }
  )

  cogs.seedWeatherService(service)
  cogs.seedCurrentZip(.newYork)
  let group = WeatherEffects(
    notifier: Notifier { _ in },
    clock: clock,
    initialZipCodes: []
  )
  .install(in: cogs)

  try await clock.waitForScheduledSleep()
  #expect(cogs.peek(weatherReport[.newYork]) == nil)

  clock.advance(by: .seconds(3_600))
  try await clock.waitForScheduledSleep()

  #expect(cogs.peek(weatherReport[.newYork]) == refreshedWeather)
  let turnNames = cogs.debugHistory.entries
    .filter { $0.event == .turn }
    .map(\.name)
  #expect(turnNames == ["weather.refreshStarted", "weather.check"])

  group.cancel()
  clock.finish()
}

@MainActor
@Test func aFailedHourlyRefreshDoesNotStopLaterOnes() async throws {
  let clock = WeatherTestClock()
  let cogs = Cogtext.forTesting()
  let refreshedWeather = Weather(kind: .clear, temperatureF: 75)
  let attempts = OSAllocatedUnfairLock(initialState: 0)
  let service = WeatherService(
    weather: { _ in
      let attempt = attempts.withLock { count in
        count += 1
        return count
      }
      if attempt == 1 { throw WeatherRequestFailure() }
      return refreshedWeather
    },
    advisories: { _ in [] }
  )

  cogs.seedWeatherService(service)
  cogs.seedCurrentZip(.newYork)
  let group = WeatherEffects(
    notifier: Notifier { _ in },
    clock: clock,
    initialZipCodes: []
  )
  .install(in: cogs)

  try await clock.waitForScheduledSleep()
  clock.advance(by: .seconds(3_600))
  try await clock.waitForScheduledSleep()

  #expect(cogs.peek(weatherLoadStatus[.newYork]) == .failed)
  #expect(cogs.peek(weatherReport[.newYork]) == nil)

  clock.advance(by: .seconds(3_600))
  try await clock.waitForScheduledSleep()

  #expect(cogs.peek(weatherReport[.newYork]) == refreshedWeather)
  #expect(cogs.peek(weatherLoadStatus[.newYork]) == .idle)
  #expect(attempts.withLock { $0 } == 2)

  group.cancel()
  clock.finish()
}

private nonisolated struct WeatherRequestFailure: Error {}

/// A clock whose time only moves when a test moves it.
///
/// The two streams are a strict ping-pong between exactly two consumers: the
/// effect task alone awaits `ticks` inside `sleep(until:tolerance:)`, and the
/// test task alone awaits `scheduledEvents` through `waitForScheduledSleep`.
/// Nothing here may grow a second consumer of either stream.
private nonisolated final class WeatherTestClock: Clock, @unchecked Sendable {
  /// Fails a wait rather than hanging it when the awaited signal never lands.
  struct SignalTimeout: Error, CustomStringConvertible {
    let description = "the effect task scheduled no sleep before the deadline"
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

  /// Waits until the effect task is asleep on this clock again.
  ///
  /// The wait is bounded on the real clock. An effect task that has died —
  /// which is exactly what a refresh loop does when it lets an error escape —
  /// will never schedule another sleep, and an unbounded wait would hang the
  /// suite instead of reporting the regression.
  func waitForScheduledSleep(within budget: Swift.Duration = .seconds(5)) async throws {
    let scheduled = try await withThrowingTaskGroup(of: Bool.self) { group in
      group.addTask {
        var iterator = self.scheduledEvents.makeAsyncIterator()
        return await iterator.next() != nil
      }
      group.addTask {
        try await Task.sleep(for: budget)
        return false
      }
      let first = try await group.next() ?? false
      group.cancelAll()
      return first
    }
    guard scheduled else { throw SignalTimeout() }
  }

  func advance(by duration: Swift.Duration) {
    nowState.withLock { instant in
      instant = instant.advanced(by: duration)
    }
    tickContinuation.yield()
  }

  func finish() {
    tickContinuation.finish()
    scheduledContinuation.finish()
  }
}

#endif
