import Cog
import CogTesting
import Testing

@MainActor
@Test func weatherStateStartsWithoutACurrentLocation() {
  let cogs = Cogs.forTesting()

  #expect(cogs.peek(currentZipCode) == nil)
}

#if DEBUG

@MainActor
@Test func weatherDerivationsFollowTheLatestSuccessfulReading() async throws {
  let cogs = Cogs.forTesting()
  let requests = WeatherRequestController()
  var starts = requests.starts.makeAsyncIterator()
  cogs.seedWeatherService(requests.service)

  if case .pending(value: nil, hasSucceeded: false) =
    cogs.meta.peek(weatherForecast[.newYork])
  {
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

  let advisoryRefresh = cogs.refresh(weatherForecast[.newYork])
  let advisoryRun = try #require(await starts.next())
  let advisoryOutcome = await resolveWeatherRefresh(advisoryRefresh) {
    await requests.succeed(
      advisoryRun,
      with: WeatherReading(.clear, 75, advisories: [.heat])
    )
  }
  guard case .success = advisoryOutcome else {
    Issue.record("The advisory refresh did not complete successfully")
    return
  }

  #expect(cogs.peek(isSunny[.newYork]))
  #expect(!cogs.peek(isNiceOutside[.newYork]))

  let hotRefresh = cogs.refresh(weatherForecast[.newYork])
  let hotRun = try #require(await starts.next())
  let hotOutcome = await resolveWeatherRefresh(hotRefresh) {
    await requests.succeed(
      hotRun,
      with: WeatherReading(.clear, 94)
    )
  }
  guard case .success = hotOutcome else {
    Issue.record("The hot-weather refresh did not complete successfully")
    return
  }

  #expect(!cogs.peek(isNiceOutside[.newYork]))
}

@MainActor
@Test func aFailedRefreshKeepsTheLastForecastInItsMetadata() async throws {
  let cogs = Cogs.forTesting()
  let requests = WeatherRequestController()
  var starts = requests.starts.makeAsyncIterator()
  cogs.seedWeatherService(requests.service)

  _ = cogs.meta.peek(weatherForecast[.newYork])
  let initialRun = try #require(await starts.next())
  let lastGoodReading = WeatherReading(.cloudy, 60)
  try await resolveWeatherRequest(in: cogs) {
    await requests.succeed(initialRun, with: lastGoodReading)
  }

  let failedRefresh = cogs.refresh(weatherForecast[.newYork])
  if case .pending(value: .some(let reading), hasSucceeded: true) =
    cogs.meta.peek(weatherForecast[.newYork])
  {
    #expect(reading == lastGoodReading)
  } else {
    Issue.record("Reload pending should retain the last successful reading")
  }
  let failedRun = try #require(await starts.next())
  let failedOutcome = await resolveWeatherRefresh(failedRefresh) {
    await requests.fail(failedRun, with: RefreshFailure())
  }
  guard case .failure(let refreshError) = failedOutcome else {
    Issue.record("The failed refresh handle did not retain its error")
    return
  }
  #expect(refreshError is RefreshFailure)

  if case .failure(let error, value: .some(let reading), hasSucceeded: true) =
    cogs.meta.peek(weatherForecast[.newYork])
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
  let cogs = Cogs.forTesting()
  let requests = WeatherRequestController()
  var starts = requests.starts.makeAsyncIterator()
  cogs.seedWeatherService(requests.service)

  _ = cogs.meta.peek(weatherForecast[.newYork])
  let replacedRun = try #require(await starts.next())

  let currentRefresh = cogs.refresh(weatherForecast[.newYork])
  let currentRun = try #require(await starts.next())
  #expect(replacedRun.zip == currentRun.zip)

  try await resolveWeatherRequest(in: cogs) {
    await requests.succeed(replacedRun, with: WeatherReading(.rain, 55))
  }
  if case .pending(value: nil, hasSucceeded: false) =
    cogs.meta.peek(weatherForecast[.newYork])
  {
  } else {
    Issue.record("A replaced request must not publish its late success")
  }

  let currentReading = WeatherReading(.clear, 75)
  let currentOutcome = await resolveWeatherRefresh(currentRefresh) {
    await requests.succeed(currentRun, with: currentReading)
  }
  guard case .success = currentOutcome else {
    Issue.record("The current refresh handle did not complete successfully")
    return
  }
  if case .success(let reading) = cogs.meta.peek(weatherForecast[.newYork]) {
    #expect(reading == currentReading)
  } else {
    Issue.record("The latest request should publish success")
  }
}

@MainActor
@Test func theDemoFeedAdvancesOneAtomicReadingPerRefresh() async throws {
  let cogs = Cogs.forTesting()
  cogs.seedWeatherService(.demo(latency: .zero))

  var hotDays = 0
  for request in 0..<4 {
    let checked = MainActorCleanupAcknowledgement()
    cogs.acknowledgeNextAsyncCompletionCheck(with: checked)
    if request == 0 {
      _ = cogs.meta.peek(weatherForecast[.newYork])
    } else {
      let refresh = cogs.refresh(weatherForecast[.newYork])
      guard case .success = await refresh.outcome else {
        Issue.record("The demo refresh did not complete successfully")
        return
      }
    }
    try await checked.wait()

    guard case .success(let reading?) = cogs.meta.peek(weatherForecast[.newYork]) else {
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
