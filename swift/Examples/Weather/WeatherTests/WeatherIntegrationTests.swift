#if DEBUG

import Cog
import CogTesting
import Observation
import SwiftUI
import Testing

/// Re-arms Observation after every invalidation, as SwiftUI does for `body`.
@MainActor
private final class TrackedWeatherCard {
  let cogs: Cogtext
  let zip: ZipCode
  private(set) var invalidations = 0
  private(set) var snapshots: [WeatherCardSnapshot] = []

  init(cogs: Cogtext, zip: ZipCode) {
    self.cogs = cogs
    self.zip = zip
  }

  func start() {
    render()
  }

  private func render() {
    _ = withObservationTracking {
      makeBody()
    } onChange: { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.invalidations += 1
        self.render()
      }
    }
  }

  private func makeBody() -> some View {
    WeatherCardContent(
      cogs: cogs,
      zip: zip,
      renderProbe: { [weak self] snapshot in
        self?.snapshots.append(snapshot)
      }
    ).body
  }
}

@MainActor
@Test func asyncZIPsInvalidateOnlyTheirOwnCardsAndNeverRenderATornReading() async throws {
  let cogs = Cogtext.forTesting()
  let requests = WeatherRequestController()
  var starts = requests.starts.makeAsyncIterator()
  cogs.seedWeatherService(requests.service)

  let newYorkCard = TrackedWeatherCard(cogs: cogs, zip: .newYork)
  let sanFranciscoCard = TrackedWeatherCard(cogs: cogs, zip: .sanFrancisco)
  newYorkCard.start()
  sanFranciscoCard.start()

  let firstRun = try #require(await starts.next())
  let secondRun = try #require(await starts.next())
  let runsByZip = Dictionary(uniqueKeysWithValues: [firstRun, secondRun].map { ($0.zip, $0) })
  let newYorkRun = try #require(runsByZip[.newYork])
  let sanFranciscoRun = try #require(runsByZip[.sanFrancisco])
  let newYorkReading = WeatherReading(.cloudy, 55)
  let sanFranciscoReading = WeatherReading(.cloudy, 58)

  try await resolveWeatherRequest(in: cogs) {
    await requests.succeed(newYorkRun, with: newYorkReading)
  }
  #expect(newYorkCard.invalidations == 1)
  #expect(sanFranciscoCard.invalidations == 0)

  try await resolveWeatherRequest(in: cogs) {
    await requests.succeed(sanFranciscoRun, with: sanFranciscoReading)
  }
  #expect(newYorkCard.invalidations == 1)
  #expect(sanFranciscoCard.invalidations == 1)

  cogs.refresh(weatherForecast[.sanFrancisco])
  let changedRun = try #require(await starts.next())
  #expect(changedRun.zip == .sanFrancisco)
  let changedReading = WeatherReading(.clear, 75)
  try await resolveWeatherRequest(in: cogs) {
    await requests.succeed(changedRun, with: changedReading)
  }

  #expect(newYorkCard.invalidations == 1)
  #expect(
    newYorkCard.snapshots == [
      WeatherCardSnapshot(zip: .newYork, report: nil, isNice: false),
      WeatherCardSnapshot(zip: .newYork, report: newYorkReading.weather, isNice: false),
    ]
  )
  #expect(sanFranciscoCard.invalidations == 4)
  #expect(
    sanFranciscoCard.snapshots == [
      WeatherCardSnapshot(zip: .sanFrancisco, report: nil, isNice: false),
      WeatherCardSnapshot(
        zip: .sanFrancisco,
        report: sanFranciscoReading.weather,
        isNice: false
      ),
      // Reload pending retains the prior success as one atomic reading.
      WeatherCardSnapshot(
        zip: .sanFrancisco,
        report: sanFranciscoReading.weather,
        isNice: false
      ),
      WeatherCardSnapshot(
        zip: .sanFrancisco,
        report: changedReading.weather,
        isNice: true
      ),
      // The full phase and `isNice` have separate boundary notices. This
      // direct harness re-arms between them, so both renders must see the same
      // settled turn rather than a mixed pair.
      WeatherCardSnapshot(
        zip: .sanFrancisco,
        report: changedReading.weather,
        isNice: true
      ),
    ]
  )
}

@MainActor
@Test func asyncNoticesPrecedeEffectsAndEqualDerivedValuesStayQuiet() async throws {
  let cogs = Cogtext.forTesting()
  let requests = WeatherRequestController()
  var starts = requests.starts.makeAsyncIterator()
  cogs.seedCurrentZip(.newYork)
  cogs.seedWeatherService(requests.service)
  var alerts: [String] = []
  let effects = WeatherEffects(
    notifier: Notifier { alerts.append($0) },
    initialZipCodes: []
  ).install(in: cogs)
  let card = TrackedWeatherCard(cogs: cogs, zip: .newYork)
  card.start()

  let initialRun = try #require(await starts.next())
  try await resolveWeatherRequest(in: cogs) {
    await requests.succeed(initialRun, with: WeatherReading(.cloudy, 55))
  }
  #expect(alerts.isEmpty)

  cogs.refresh(weatherForecast[.newYork])
  let niceRun = try #require(await starts.next())
  try await resolveWeatherRequest(in: cogs) {
    await requests.succeed(niceRun, with: WeatherReading(.clear, 75))
  }

  #expect(alerts == ["It is nice outside!"])
  let changedEntries = entriesInLatestTurn(cogs)
  let noticeIndexes = changedEntries.indices.filter { changedEntries[$0].event == .notice }
  let effectIndexes = changedEntries.indices.filter { changedEntries[$0].event == .effect }
  #expect(!noticeIndexes.isEmpty)
  #expect(effectIndexes.count == 1)
  #expect(noticeIndexes.allSatisfy { $0 < effectIndexes[0] })

  cogs.refresh(weatherForecast[.newYork])
  let stillNiceRun = try #require(await starts.next())
  try await resolveWeatherRequest(in: cogs) {
    await requests.succeed(stillNiceRun, with: WeatherReading(.partlyCloudy, 80))
  }

  #expect(alerts == ["It is nice outside!"])
  let equalEntries = entriesInLatestTurn(cogs)
  let noticeNames = equalEntries.filter { $0.event == .notice }.map(\.name)
  #expect(noticeNames.contains("weather.forecast[10001]"))
  #expect(!noticeNames.contains("weather.isNice[10001]"))
  effects.cancel()
  withExtendedLifetime(card) {}
}

@MainActor
private func entriesInLatestTurn(_ cogs: Cogtext) -> [CogHistoryEntry] {
  let entries = cogs.debugHistory.entries
  guard let turn = entries.last(where: { $0.event == .turn })?.turn else { return [] }
  return entries.filter { $0.turn == turn }
}

#endif
