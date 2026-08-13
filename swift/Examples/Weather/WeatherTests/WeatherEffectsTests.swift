#if DEBUG

import Cog
import CogTesting
import Testing

@MainActor
@Test func niceWeatherEffectSkipsInstallationAndAlertsOnFalseToTrueTransitions() async throws {
  let cogs = Cogs.forTesting()
  let requests = WeatherRequestController()
  var starts = requests.starts.makeAsyncIterator()
  var alerts: [String] = []
  let notifier = Notifier { alerts.append($0) }

  cogs.seedCurrentZip(.newYork)
  cogs.seedWeatherService(requests.service)

  WeatherEffects(notifier: notifier, initialZipCodes: []).install(in: cogs)
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
}

@MainActor
@Test func installedEffectsDoNotRetainAnIsolatedRuntime() async throws {
  var cogs: Cogs? = Cogs.forTesting()
  let effectsReleased = MainActorCleanupAcknowledgement()
  cogs?.effects.acknowledgeDeinitCleanup(with: effectsReleased)

  WeatherEffects(notifier: Notifier { _ in }, initialZipCodes: [])
    .install(in: try #require(cogs))

  cogs = nil
  try await effectsReleased.wait()
}

@MainActor
@Test func injectedClockRunsTheHourlyWeatherOperation() async throws {
  let clock = TestClock()
  let cogs = Cogs.forTesting()
  let requests = WeatherRequestController()
  var starts = requests.starts.makeAsyncIterator()
  cogs.seedWeatherService(requests.service)
  cogs.seedCurrentZip(.newYork)
  let refreshedWeather = Weather(kind: .clear, temperatureF: 75)
  WeatherEffects(
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

  clock.finish()
}

@MainActor
@Test func installingEffectsPublishesTheCadenceTheLoopActuallyKeeps() {
  let cogs = Cogs.forTesting()
  cogs.seedCurrentZip(.newYork)

  #expect(cogs.peek(refreshInterval) == nil)
  #expect(cogs.peek(receivesHourlyUpdates[.newYork]) == false)

  WeatherEffects(
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

}

@MainActor
@Test func aFailedHourlyRefreshDoesNotStopLaterOnes() async throws {
  let clock = TestClock()
  let cogs = Cogs.forTesting()
  let requests = WeatherRequestController()
  var starts = requests.starts.makeAsyncIterator()
  cogs.seedWeatherService(requests.service)
  cogs.seedCurrentZip(.newYork)
  let refreshedWeather = Weather(kind: .clear, temperatureF: 75)
  WeatherEffects(
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

  if case .failure(_, value: .some(let reading), hasSucceeded: true) =
    cogs.meta.peek(weatherForecast[.newYork])
  {
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

  clock.finish()
}

private nonisolated struct WeatherRequestFailure: Error {}

#endif
