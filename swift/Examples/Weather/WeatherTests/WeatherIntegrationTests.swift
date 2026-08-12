#if DEBUG

import Cog
import CogTesting
import Observation
import SwiftUI
import Testing

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

  func renderOnce() {
    _ = withObservationTracking {
      makeBody()
    } onChange: { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.invalidations += 1
        _ = self.makeBody()
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
@Test func oneZIPInvalidatesOnlyItsCardAndNeverRendersATornPair() {
  let cogs = Cogtext.forTesting()
  let newYorkWeather = Weather(kind: .cloudy, temperatureF: 55)
  let sanFranciscoWeather = Weather(kind: .cloudy, temperatureF: 58)
  cogs.seedWeather(newYorkWeather, heatAdvisory: false, zip: .newYork)
  cogs.seedWeather(sanFranciscoWeather, heatAdvisory: false, zip: .sanFrancisco)

  let newYorkCard = TrackedWeatherCard(cogs: cogs, zip: .newYork)
  let sanFranciscoCard = TrackedWeatherCard(cogs: cogs, zip: .sanFrancisco)
  newYorkCard.renderOnce()
  sanFranciscoCard.renderOnce()

  let changedWeather = Weather(kind: .clear, temperatureF: 75)
  cogs.stubWeather(changedWeather, heatAdvisory: false, zip: .sanFrancisco)

  #expect(newYorkCard.invalidations == 0)
  #expect(
    newYorkCard.snapshots == [
      WeatherCardSnapshot(zip: .newYork, report: newYorkWeather, isNice: false)
    ]
  )
  #expect(sanFranciscoCard.invalidations == 1)
  #expect(
    sanFranciscoCard.snapshots == [
      WeatherCardSnapshot(zip: .sanFrancisco, report: sanFranciscoWeather, isNice: false),
      WeatherCardSnapshot(zip: .sanFrancisco, report: changedWeather, isNice: true),
    ]
  )
}

@MainActor
@Test func changedWeatherNoticesPrecedeEffectsAndEqualDerivedValuesStayQuiet() {
  let cogs = Cogtext.forTesting()
  cogs.seedCurrentZip(.newYork)
  cogs.seedWeather(
    Weather(kind: .cloudy, temperatureF: 55),
    heatAdvisory: false,
    zip: .newYork
  )
  var alerts: [String] = []
  let effects = WeatherEffects(
    notifier: Notifier { alerts.append($0) },
    initialZipCodes: []
  ).install(in: cogs)
  let firstRender = TrackedWeatherCard(cogs: cogs, zip: .newYork)
  firstRender.renderOnce()

  cogs.stubWeather(
    Weather(kind: .clear, temperatureF: 75),
    heatAdvisory: false,
    zip: .newYork
  )

  #expect(alerts == ["It is nice outside!"])
  let changedEntries = entriesInLatestTurn(cogs)
  let noticeIndexes = changedEntries.indices.filter { changedEntries[$0].event == .notice }
  let effectIndexes = changedEntries.indices.filter { changedEntries[$0].event == .effect }
  #expect(!noticeIndexes.isEmpty)
  #expect(effectIndexes.count == 1)
  #expect(noticeIndexes.allSatisfy { $0 < effectIndexes[0] })

  let equalDerivedRender = TrackedWeatherCard(cogs: cogs, zip: .newYork)
  equalDerivedRender.renderOnce()
  cogs.stubWeather(
    Weather(kind: .partlyCloudy, temperatureF: 80),
    heatAdvisory: false,
    zip: .newYork
  )

  #expect(equalDerivedRender.invalidations == 1)
  let equalEntries = entriesInLatestTurn(cogs)
  let noticeNames = equalEntries.filter { $0.event == .notice }.map(\.name)
  #expect(noticeNames.contains("weather.report[10001]"))
  #expect(!noticeNames.contains("weather.isNice[10001]"))
  effects.cancel()
}

@MainActor
private func entriesInLatestTurn(_ cogs: Cogtext) -> [CogHistoryEntry] {
  let entries = cogs.debugHistory.entries
  guard let turn = entries.last(where: { $0.event == .turn })?.turn else { return [] }
  return entries.filter { $0.turn == turn }
}

#endif
