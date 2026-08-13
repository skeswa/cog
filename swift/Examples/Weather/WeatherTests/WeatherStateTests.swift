import Cog
import CogTesting
import Testing

@MainActor
@Test func weatherStateStartsWithoutACurrentLocation() {
  let cogs = Cogtext.forTesting()

  #expect(cogs.peek(currentZipCode) == nil)
}

#if DEBUG

@MainActor
@Test func weatherDerivationsFollowTheLatestSuccessfulReading() async throws {
  let cogs = Cogtext.forTesting()
  let requests = WeatherRequestController()
  var starts = requests.starts.makeAsyncIterator()
  cogs.seedWeatherService(requests.service)

  if case .pending(previous: .none) = cogs.phase.peek(weatherForecast[.newYork]) {
  } else {
    Issue.record("A forecast's first demand should synchronously return initial pending")
  }
  let initialRun = try #require(await starts.next())
  try await resolveWeatherRequest(in: cogs) {
    await requests.succeed(
      initialRun,
      with: WeatherReading(.clear, 75)
    )
  }

  #expect(cogs.peek(isSunny[.newYork]))
  #expect(cogs.peek(isNiceOutside[.newYork]))

  cogs.refresh(weatherForecast[.newYork])
  let advisoryRun = try #require(await starts.next())
  try await resolveWeatherRequest(in: cogs) {
    await requests.succeed(
      advisoryRun,
      with: WeatherReading(.clear, 75, advisories: [.heat])
    )
  }

  #expect(cogs.peek(isSunny[.newYork]))
  #expect(!cogs.peek(isNiceOutside[.newYork]))

  cogs.refresh(weatherForecast[.newYork])
  let hotRun = try #require(await starts.next())
  try await resolveWeatherRequest(in: cogs) {
    await requests.succeed(
      hotRun,
      with: WeatherReading(.clear, 94)
    )
  }

  #expect(!cogs.peek(isNiceOutside[.newYork]))
}

@MainActor
@Test func aFailedRefreshKeepsTheLastForecastInItsPhase() async throws {
  let cogs = Cogtext.forTesting()
  let requests = WeatherRequestController()
  var starts = requests.starts.makeAsyncIterator()
  cogs.seedWeatherService(requests.service)

  _ = cogs.phase.peek(weatherForecast[.newYork])
  let initialRun = try #require(await starts.next())
  let lastGoodReading = WeatherReading(.cloudy, 60)
  try await resolveWeatherRequest(in: cogs) {
    await requests.succeed(initialRun, with: lastGoodReading)
  }

  cogs.refresh(weatherForecast[.newYork])
  if case .pending(previous: .some(let reading)) = cogs.phase.peek(weatherForecast[.newYork]) {
    #expect(reading == lastGoodReading)
  } else {
    Issue.record("Reload pending should retain the last successful reading")
  }
  let failedRun = try #require(await starts.next())
  try await resolveWeatherRequest(in: cogs) {
    await requests.fail(failedRun, with: RefreshFailure())
  }

  if case .failure(let error, previous: .some(let reading)) =
    cogs.phase.peek(weatherForecast[.newYork])
  {
    #expect(error is RefreshFailure)
    #expect(reading == lastGoodReading)
  } else {
    Issue.record("Failure should retain the last successful reading")
  }
  #expect(cogs.peek(weatherForecast[.newYork]) == lastGoodReading)
}

@MainActor
@Test func refreshingInFlightForecastReplacesItsGeneration() async throws {
  let cogs = Cogtext.forTesting()
  let requests = WeatherRequestController()
  var starts = requests.starts.makeAsyncIterator()
  cogs.seedWeatherService(requests.service)

  _ = cogs.phase.peek(weatherForecast[.newYork])
  let replacedRun = try #require(await starts.next())

  cogs.refresh(weatherForecast[.newYork])
  let currentRun = try #require(await starts.next())
  #expect(replacedRun.zip == currentRun.zip)

  try await resolveWeatherRequest(in: cogs) {
    await requests.succeed(replacedRun, with: WeatherReading(.rain, 55))
  }
  if case .pending(previous: .none) = cogs.phase.peek(weatherForecast[.newYork]) {
  } else {
    Issue.record("A replaced request must not publish its late success")
  }

  let currentReading = WeatherReading(.clear, 75)
  try await resolveWeatherRequest(in: cogs) {
    await requests.succeed(currentRun, with: currentReading)
  }
  if case .success(let reading) = cogs.phase.peek(weatherForecast[.newYork]) {
    #expect(reading == currentReading)
  } else {
    Issue.record("The latest request should publish success")
  }
}

@MainActor
@Test func theDemoFeedAdvancesOneAtomicReadingPerRefresh() async throws {
  let cogs = Cogtext.forTesting()
  cogs.seedWeatherService(.demo(latency: .zero))

  var hotDays = 0
  for request in 0..<4 {
    let checked = MainActorCleanupAcknowledgement()
    cogs.acknowledgeNextAsyncCompletionCheck(with: checked)
    if request == 0 {
      _ = cogs.phase.peek(weatherForecast[.newYork])
    } else {
      cogs.refresh(weatherForecast[.newYork])
    }
    try await checked.wait()

    guard case .success(let reading?) = cogs.phase.peek(weatherForecast[.newYork]) else {
      Issue.record("The demo request did not publish a reading")
      return
    }
    if reading.weather.temperatureF > 90 {
      hotDays += 1
      #expect(reading.advisories.contains(.heat))
    } else {
      #expect(!reading.advisories.contains(.heat))
    }
  }

  #expect(hotDays == 1)
}

private nonisolated struct RefreshFailure: Error {}

#endif
