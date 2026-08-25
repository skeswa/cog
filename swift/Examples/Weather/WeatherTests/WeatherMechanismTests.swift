#if DEBUG

import Cog
import CogTesting
import Testing

@MainActor
@Test func niceWeatherReactionSkipsAssemblyAndAlertsOnFalseToTrueTransitions() async throws {
  let requests = WeatherRequestController()
  var starts = requests.starts.makeAsyncIterator()
  var alerts: [String] = []
  let notifier = Notifier { alerts.append($0) }

  let cogs = Cogs.forTesting(
    seeding: { cogs in
      cogs.seedCurrentZip(.newYork)
      cogs.seedWeatherService(requests.service)
    },
    mechanisms: [WeatherMechanism(notifier: notifier, initialZipCodes: [])]
  )
  let initialRun = try #require(await starts.next())
  try await resolveWeatherRequest(in: cogs) {
    await requests.succeed(initialRun, with: WeatherReading(.cloudy, 60))
  }
  #expect(alerts.isEmpty)

  cogs.refresh(weatherForecastCogs[.newYork])
  let firstNiceRun = try #require(await starts.next())
  try await resolveWeatherRequest(in: cogs) {
    await requests.succeed(firstNiceRun, with: WeatherReading(.clear, 75))
  }
  #expect(alerts == ["It is nice outside!"])

  cogs.refresh(weatherForecastCogs[.newYork])
  let stillNiceRun = try #require(await starts.next())
  try await resolveWeatherRequest(in: cogs) {
    await requests.succeed(stillNiceRun, with: WeatherReading(.partlyCloudy, 80))
  }
  #expect(alerts == ["It is nice outside!"])

  cogs.refresh(weatherForecastCogs[.newYork])
  let rainRun = try #require(await starts.next())
  try await resolveWeatherRequest(in: cogs) {
    await requests.succeed(rainRun, with: WeatherReading(.rain, 55))
  }
  cogs.refresh(weatherForecastCogs[.newYork])
  let secondNiceRun = try #require(await starts.next())
  try await resolveWeatherRequest(in: cogs) {
    await requests.succeed(secondNiceRun, with: WeatherReading(.clear, 70))
  }
  #expect(alerts == ["It is nice outside!", "It is nice outside!"])

  let effectNames = cogs.debugHistory.entries
    .filter { $0.event == .effect }
    .map(\.name)
  #expect(effectNames.contains("Weather.niceAlert"))
}

@MainActor
@Test func assembledMechanismsDoNotRetainAnIsolatedRuntime() async throws {
  var cogs: Cogs? = Cogs.forTesting(mechanisms: [
    WeatherMechanism(notifier: Notifier { _ in }, initialZipCodes: [])
  ])
  let teardownReleased = MainActorCleanupAcknowledgement()
  cogs?.acknowledgeDeinitCleanup(with: teardownReleased)

  cogs = nil
  try await teardownReleased.wait()
}

@MainActor
@Test func injectedClockRunsTheHourlyWeatherOperation() async throws {
  let clock = TestClock()
  let requests = WeatherRequestController()
  var starts = requests.starts.makeAsyncIterator()
  let refreshedWeather = Weather(kind: .clear, temperatureF: 75)
  let cogs = Cogs.forTesting(
    seeding: { cogs in
      cogs.seedWeatherService(requests.service)
      cogs.seedCurrentZip(.newYork)
    },
    mechanisms: [
      WeatherMechanism(
        notifier: Notifier { _ in },
        clock: clock,
        initialZipCodes: []
      )
    ]
  )

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

  #expect(cogs.peek(weatherForecastCogs[.newYork])?.weather == refreshedWeather)
  let turnNames = cogs.debugHistory.entries
    .filter { $0.event == .turn }
    .map(\.name)
  #expect(turnNames.contains { $0.hasSuffix("[10001] pending") })
  #expect(turnNames.last?.hasSuffix("[10001] success") == true)

  clock.finish()
}

@MainActor
@Test func assemblingTheMechanismPublishesTheCadenceTheLoopActuallyKeeps() {
  let cogs = Cogs.forTesting(
    seeding: { cogs in
      cogs.seedCurrentZip(.newYork)
      // Seeding precedes `operate`, so this observes the resting defaults.
      #expect(cogs.peek(refreshIntervalCog) == nil)
      #expect(cogs.peek(receivesHourlyUpdatesCogs[.newYork]) == false)
    },
    mechanisms: [
      WeatherMechanism(
        notifier: Notifier { _ in },
        initialZipCodes: [],
        hourlyRefreshInterval: .seconds(5)
      )
    ]
  )

  #expect(cogs.peek(refreshIntervalCog) == .seconds(5))
  #expect(cogs.peek(refreshIntervalCog)?.cadenceDescription == "5 seconds")
  #expect(cogs.peek(refreshIntervalCog)?.shortCadenceDescription == "5 sec")
  #expect(cogs.peek(receivesHourlyUpdatesCogs[.newYork]) == true)
  #expect(cogs.peek(receivesHourlyUpdatesCogs[.seattle]) == false)

}

@MainActor
@Test func aFailedHourlyRefreshDoesNotStopLaterOnes() async throws {
  let clock = TestClock()
  let requests = WeatherRequestController()
  var starts = requests.starts.makeAsyncIterator()
  let refreshedWeather = Weather(kind: .clear, temperatureF: 75)
  let cogs = Cogs.forTesting(
    seeding: { cogs in
      cogs.seedWeatherService(requests.service)
      cogs.seedCurrentZip(.newYork)
    },
    mechanisms: [
      WeatherMechanism(
        notifier: Notifier { _ in },
        clock: clock,
        initialZipCodes: []
      )
    ]
  )

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

  let failedStatus = cogs.status.peek(weatherForecastCogs[.newYork])
  if failedStatus.kind == .failure, failedStatus.hasSucceeded {
    #expect(failedStatus.value == initialReading)
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

  #expect(cogs.peek(weatherForecastCogs[.newYork])?.weather == refreshedWeather)

  clock.finish()
}

private nonisolated struct WeatherRequestFailure: Error {}

#endif
