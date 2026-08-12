import Cog
import CogTesting
import Testing
import os

@MainActor
@Test func weatherStateStartsWithoutACurrentLocation() {
  let cogs = Cogtext.forTesting()

  #expect(cogs.peek(currentZipCode) == nil)
}

// The rest of this file drives `checkWeather` and the derived values through
// the states the cards render — failed, cancelled, already refreshing, and
// under a heat advisory — none of which the canned feed alone reaches.
#if DEBUG

@MainActor
@Test func aHeatAdvisoryKeepsAClearDayFromBeingNice() {
  let cogs = Cogtext.forTesting()
  cogs.seedWeather(
    Weather(kind: .clear, temperatureF: 75),
    heatAdvisory: false,
    zip: .newYork
  )

  #expect(cogs.peek(isNiceOutside[.newYork]) == true)

  cogs.stubWeather(
    Weather(kind: .clear, temperatureF: 75),
    heatAdvisory: true,
    zip: .newYork
  )

  #expect(cogs.peek(isSunny[.newYork]) == true)
  #expect(cogs.peek(isNiceOutside[.newYork]) == false)

  cogs.stubWeather(
    Weather(kind: .clear, temperatureF: 94),
    heatAdvisory: false,
    zip: .newYork
  )

  #expect(cogs.peek(isNiceOutside[.newYork]) == false)
}

@MainActor
@Test func aFailedRefreshRecordsFailureAndKeepsTheLastForecast() async {
  let cogs = Cogtext.forTesting()
  let lastGoodForecast = Weather(kind: .cloudy, temperatureF: 60)
  cogs.seedWeather(lastGoodForecast, heatAdvisory: false, zip: .newYork)
  cogs.seedWeatherService(
    WeatherService(
      weather: { _ in throw RefreshFailure() },
      advisories: { _ in [] }
    )
  )

  await #expect(throws: RefreshFailure.self) {
    try await cogs.checkWeather(.newYork)
  }

  #expect(cogs.peek(weatherLoadStatus[.newYork]) == .failed)
  #expect(cogs.peek(weatherReport[.newYork]) == lastGoodForecast)
}

@MainActor
@Test(.timeLimit(.minutes(1))) func aCancelledRefreshReturnsToIdle() async {
  let cogs = Cogtext.forTesting()
  cogs.seedWeatherService(
    WeatherService(
      weather: { _ in
        try await Task.sleep(for: .seconds(3_600))
        return Weather(kind: .clear, temperatureF: 75)
      },
      advisories: { _ in [] }
    )
  )

  let refresh = Task { try await cogs.checkWeather(.newYork) }
  while cogs.peek(weatherLoadStatus[.newYork]) != .refreshing {
    await Task.yield()
  }

  refresh.cancel()
  await #expect(throws: CancellationError.self) {
    try await refresh.value
  }

  #expect(cogs.peek(weatherLoadStatus[.newYork]) == .idle)
  #expect(cogs.peek(weatherReport[.newYork]) == nil)
}

@MainActor
@Test(.timeLimit(.minutes(1))) func aRefreshAlreadyInFlightIsNotStartedTwice() async throws {
  let cogs = Cogtext.forTesting()
  let requests = OSAllocatedUnfairLock(initialState: 0)
  cogs.seedWeatherService(
    WeatherService(
      weather: { _ in
        requests.withLock { $0 += 1 }
        try await Task.sleep(for: .seconds(3_600))
        return Weather(kind: .clear, temperatureF: 75)
      },
      advisories: { _ in [] }
    )
  )

  let refresh = Task { try await cogs.checkWeather(.newYork) }
  while requests.withLock({ $0 }) == 0 {
    await Task.yield()
  }

  // The refresh button and the hourly loop can ask at the same moment. The
  // second ask has to fall in behind the one in flight, not race it.
  try await cogs.checkWeather(.newYork)

  #expect(requests.withLock { $0 } == 1)
  #expect(cogs.peek(weatherLoadStatus[.newYork]) == .refreshing)

  refresh.cancel()
  _ = await refresh.result
}

@MainActor
@Test func theDemoFeedGivesBothRequestsOfARefreshTheSameDay() async throws {
  let cogs = Cogtext.forTesting()
  cogs.seedWeatherService(.demo(latency: .zero))

  var hotDays = 0
  for _ in 0..<4 {
    try await cogs.checkWeather(.newYork)

    let report = try #require(cogs.peek(weatherReport[.newYork]))
    if report.temperatureF > 90 {
      hotDays += 1
      #expect(cogs.peek(heatAdvisory[.newYork]))
    } else {
      #expect(!cogs.peek(heatAdvisory[.newYork]))
    }
  }

  // A whole rotation, so the pairing is proven on every reading rather than on
  // whichever one happened to come up first.
  #expect(hotDays == 1)
}

private nonisolated struct RefreshFailure: Error {}

#endif
