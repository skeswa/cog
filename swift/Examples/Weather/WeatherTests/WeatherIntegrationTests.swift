#if DEBUG

import Cog
import CogTesting
import Observation
import Testing

/// Tracks the same graph projection as a card body: one-shot Observation with
/// the re-render deferred to the next explicit frame.
///
/// `onChange` only counts the invalidation and marks the card dirty — it never
/// evaluates `body` reentrantly, because SwiftUI cannot: Cog's flush is
/// synchronous on the MainActor, so a real body evaluation only happens after
/// the turn completes. A turn that mutates several of the card's boundaries —
/// a forecast's status and its
/// `isNice` derivation — therefore invalidates once, exactly like a frame.
/// Tests call ``renderFrame()`` at their settle points to evaluate the body
/// and re-arm.
@MainActor
private final class TrackedWeatherCard {
  let cogs: Cogs
  let zip: ZipCode
  private(set) var invalidations = 0
  private(set) var snapshots: [WeatherCardSnapshot] = []
  private var needsRender = false

  init(cogs: Cogs, zip: ZipCode) {
    self.cogs = cogs
    self.zip = zip
  }

  func start() {
    render()
  }

  /// Evaluates the body once if an invalidation is pending, as the next
  /// SwiftUI frame would, and re-arms tracking.
  func renderFrame() {
    guard needsRender else { return }
    needsRender = false
    render()
  }

  private func render() {
    withObservationTracking {
      let weatherCard = WeatherCardReading(cogs: cogs, zip: zip)
      snapshots.append(weatherCard.snapshot)
    } onChange: { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.invalidations += 1
        self.needsRender = true
      }
    }
  }
}

@MainActor
@Test func asyncZIPsInvalidateOnlyTheirOwnCardsAndNeverRenderATornReading() async throws {
  let cogs = Cogs.forTesting()
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
  // One status read supplies retained content and request chrome. The
  // success turn invalidates that boundary once.
  #expect(newYorkCard.invalidations == 1)
  #expect(sanFranciscoCard.invalidations == 0)
  newYorkCard.renderFrame()

  try await resolveWeatherRequest(in: cogs) {
    await requests.succeed(sanFranciscoRun, with: sanFranciscoReading)
  }
  #expect(newYorkCard.invalidations == 1)
  #expect(sanFranciscoCard.invalidations == 1)
  sanFranciscoCard.renderFrame()

  cogs.refresh(weatherForecastCogs[.sanFrancisco])
  // Reload pending notices the status boundary, and the frame counts once.
  #expect(sanFranciscoCard.invalidations == 2)
  sanFranciscoCard.renderFrame()
  let changedRun = try #require(await starts.next())
  #expect(changedRun.zip == .sanFrancisco)
  let changedReading = WeatherReading(.clear, 75)
  try await resolveWeatherRequest(in: cogs) {
    await requests.succeed(changedRun, with: changedReading)
  }
  #expect(sanFranciscoCard.invalidations == 3)
  sanFranciscoCard.renderFrame()

  #expect(newYorkCard.invalidations == 1)
  #expect(
    newYorkCard.snapshots == [
      WeatherCardSnapshot(zip: .newYork, report: nil, isNice: false),
      WeatherCardSnapshot(zip: .newYork, report: newYorkReading.weather, isNice: false),
    ]
  )
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
      // The changed success turn mutates status and `isNice`
      // together; the frame renders once and must see them from the same
      // settled turn rather than a mixed set.
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
  let requests = WeatherRequestController()
  var starts = requests.starts.makeAsyncIterator()
  var alerts: [String] = []
  let cogs = Cogs.forTesting(
    seeding: { cogs in
      cogs.seedCurrentZip(.newYork)
      cogs.seedWeatherService(requests.service)
    },
    mechanisms: [
      WeatherMechanism(
        notifier: Notifier { alerts.append($0) },
        initialZipCodes: []
      )
    ]
  )
  let card = TrackedWeatherCard(cogs: cogs, zip: .newYork)
  card.start()

  let initialRun = try #require(await starts.next())
  try await resolveWeatherRequest(in: cogs) {
    await requests.succeed(initialRun, with: WeatherReading(.cloudy, 55))
  }
  #expect(alerts.isEmpty)

  cogs.refresh(weatherForecastCogs[.newYork])
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

  cogs.refresh(weatherForecastCogs[.newYork])
  let stillNiceRun = try #require(await starts.next())
  try await resolveWeatherRequest(in: cogs) {
    await requests.succeed(stillNiceRun, with: WeatherReading(.partlyCloudy, 80))
  }

  #expect(alerts == ["It is nice outside!"])
  let equalEntries = entriesInLatestTurn(cogs)
  let noticeNames = equalEntries.filter { $0.event == .notice }.map(\.name)
  #expect(noticeNames.contains("weather.forecast[10001]"))
  #expect(!noticeNames.contains("weather.isNice[10001]"))
  withExtendedLifetime(card) {}
}

@MainActor
private func entriesInLatestTurn(_ cogs: Cogs) -> [CogHistoryEntry] {
  let entries = cogs.debugHistory.entries
  guard let turn = entries.last(where: { $0.event == .turn })?.turn else { return [] }
  return entries.filter { $0.turn == turn }
}

#endif
