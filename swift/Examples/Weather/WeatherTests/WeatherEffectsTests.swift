#if DEBUG

import Cog
import CogTesting
import Testing
import os

@MainActor
@Test func niceWeatherEffectSkipsInstallationAndAlertsOnFalseToTrueTransitions() async throws {
  let cogs = Cogtext.forTesting()
  let requests = WeatherRequestController()
  var starts = requests.starts.makeAsyncIterator()
  var alerts: [String] = []
  let notifier = Notifier { alerts.append($0) }

  cogs.seedCurrentZip(.newYork)
  cogs.seedWeatherService(requests.service)

  let group = WeatherEffects(notifier: notifier, initialZipCodes: []).install(in: cogs)
  let initialRun = try #require(await starts.next())
  try await resolveWeatherRequest(in: cogs) {
    await requests.succeed(initialRun, with: WeatherReading(.cloudy, 60))
  }
  #expect(alerts.isEmpty)

  cogs.refresh(weatherForecast[.newYork])
  let firstNiceRun = try #require(await starts.next())
  try await resolveWeatherRequest(in: cogs) {
    await requests.succeed(firstNiceRun, with: WeatherReading(.clear, 75))
  }
  #expect(alerts == ["It is nice outside!"])

  cogs.refresh(weatherForecast[.newYork])
  let stillNiceRun = try #require(await starts.next())
  try await resolveWeatherRequest(in: cogs) {
    await requests.succeed(stillNiceRun, with: WeatherReading(.partlyCloudy, 80))
  }
  #expect(alerts == ["It is nice outside!"])

  cogs.refresh(weatherForecast[.newYork])
  let rainRun = try #require(await starts.next())
  try await resolveWeatherRequest(in: cogs) {
    await requests.succeed(rainRun, with: WeatherReading(.rain, 55))
  }
  cogs.refresh(weatherForecast[.newYork])
  let secondNiceRun = try #require(await starts.next())
  try await resolveWeatherRequest(in: cogs) {
    await requests.succeed(secondNiceRun, with: WeatherReading(.clear, 70))
  }
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
  let requests = WeatherRequestController()
  var starts = requests.starts.makeAsyncIterator()
  cogs.seedWeatherService(requests.service)
  cogs.seedCurrentZip(.newYork)
  let refreshedWeather = Weather(kind: .clear, temperatureF: 75)
  let group = WeatherEffects(
    notifier: Notifier { _ in },
    clock: clock,
    initialZipCodes: []
  )
  .install(in: cogs)

  let initialRun = try #require(await starts.next())
  #expect(initialRun.zip == .newYork)
  try await resolveWeatherRequest(in: cogs) {
    await requests.succeed(initialRun, with: WeatherReading(.cloudy, 60))
  }
  try await clock.waitForScheduledSleep()

  let completed = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAsyncCompletionCheck(with: completed)
  clock.advance(by: .seconds(3_600))
  let hourlyRun = try #require(await starts.next())
  #expect(hourlyRun.zip == .newYork)
  await requests.succeed(hourlyRun, with: WeatherReading(.clear, 75))
  try await completed.wait()
  try await clock.waitForScheduledSleep()

  #expect(cogs.peek(weatherForecast[.newYork])?.weather == refreshedWeather)
  let turnNames = cogs.debugHistory.entries
    .filter { $0.event == .turn }
    .map(\.name)
  #expect(turnNames.contains("weather.forecast[10001] pending"))
  #expect(turnNames.last == "weather.forecast[10001] success")

  group.cancel()
  clock.finish()
}

@MainActor
@Test func installingEffectsPublishesTheCadenceTheLoopActuallyKeeps() {
  let cogs = Cogtext.forTesting()
  cogs.seedCurrentZip(.newYork)

  #expect(cogs.peek(refreshInterval) == nil)
  #expect(cogs.peek(receivesHourlyUpdates[.newYork]) == false)

  let group = WeatherEffects(
    notifier: Notifier { _ in },
    initialZipCodes: [],
    hourlyRefreshInterval: .seconds(5)
  )
  .install(in: cogs)

  #expect(cogs.peek(refreshInterval) == .seconds(5))
  #expect(cogs.peek(refreshInterval)?.cadenceDescription == "5 seconds")
  #expect(cogs.peek(refreshInterval)?.shortCadenceDescription == "5 sec")
  #expect(cogs.peek(receivesHourlyUpdates[.newYork]) == true)
  #expect(cogs.peek(receivesHourlyUpdates[.seattle]) == false)

  group.cancel()
}

@MainActor
@Test func aFailedHourlyRefreshDoesNotStopLaterOnes() async throws {
  let clock = WeatherTestClock()
  let cogs = Cogtext.forTesting()
  let requests = WeatherRequestController()
  var starts = requests.starts.makeAsyncIterator()
  cogs.seedWeatherService(requests.service)
  cogs.seedCurrentZip(.newYork)
  let refreshedWeather = Weather(kind: .clear, temperatureF: 75)
  let group = WeatherEffects(
    notifier: Notifier { _ in },
    clock: clock,
    initialZipCodes: []
  )
  .install(in: cogs)

  let initialRun = try #require(await starts.next())
  let initialReading = WeatherReading(.cloudy, 60)
  try await resolveWeatherRequest(in: cogs) {
    await requests.succeed(initialRun, with: initialReading)
  }
  try await clock.waitForScheduledSleep()

  let failed = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAsyncCompletionCheck(with: failed)
  clock.advance(by: .seconds(3_600))
  let failedRun = try #require(await starts.next())
  await requests.fail(failedRun, with: WeatherRequestFailure())
  try await failed.wait()
  try await clock.waitForScheduledSleep()

  if case .failure(_, previous: .some(let reading)) = cogs.phase.peek(weatherForecast[.newYork]) {
    #expect(reading == initialReading)
  } else {
    Issue.record("The failed hourly refresh should retain the previous reading")
  }

  let succeeded = MainActorCleanupAcknowledgement()
  cogs.acknowledgeNextAsyncCompletionCheck(with: succeeded)
  clock.advance(by: .seconds(3_600))
  let succeededRun = try #require(await starts.next())
  await requests.succeed(succeededRun, with: WeatherReading(.clear, 75))
  try await succeeded.wait()
  try await clock.waitForScheduledSleep()

  #expect(cogs.peek(weatherForecast[.newYork])?.weather == refreshedWeather)

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
