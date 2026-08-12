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

  let group = WeatherEffects(notifier: notifier).install(in: cogs)
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
  let group = WeatherEffects(notifier: Notifier { _ in }, clock: clock)
    .install(in: cogs)

  try await clock.waitForScheduledSleep()
  #expect(cogs.read(weatherReport[.newYork]) == nil)

  clock.advance(by: .seconds(3_600))
  try await clock.waitForScheduledSleep()

  #expect(cogs.read(weatherReport[.newYork]) == refreshedWeather)
  let turnNames = cogs.debugHistory.entries
    .filter { $0.event == .turn }
    .map(\.name)
  #expect(turnNames == ["weather.check"])

  group.cancel()
  clock.finish()
}

private nonisolated final class WeatherTestClock: Clock, @unchecked Sendable {
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

  func finish() {
    tickContinuation.finish()
    scheduledContinuation.finish()
  }
}

#endif
