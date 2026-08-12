import Cog
import SwiftUI

// Weather's whole state layer: the sources, the values derived from them, and
// the ops that write them.
//
// Everything here is main-actor-isolated without saying so. The target builds
// with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (Config/Shared.xcconfig),
// which is what makes an unannotated global safe to hold a `ManualCog`, and
// what puts these declarations on the same actor as the graph they name.

private let weatherServiceSource = ManualCog<WeatherService>(
  .live,
  name: "weather.service"
)
private let weatherReportSource = ManualCogBox<Weather?, ZipCode>(
  nil,
  name: "weather.report"
)
private let heatAdvisorySource = ManualCogBox<Bool, ZipCode>(
  false,
  name: "weather.heatAdvisory"
)
private let currentZipSource = ManualCog<ZipCode?>(
  nil,
  name: "weather.currentZip"
)
private let weatherLoadStatusSource = ManualCogBox<WeatherLoadStatus, ZipCode>(
  .idle,
  name: "weather.loadStatus"
)
/// How often background refresh runs, or `nil` while none is installed.
///
/// `WeatherEffects.install` publishes its own interval here. The cadence is
/// configuration rather than weather, but the cards describe it, and a screen
/// that repeats the literal instead is a second source of the same fact — one
/// that goes quietly wrong the moment the interval changes.
private let refreshIntervalSource = ManualCog<Duration?>(
  nil,
  name: "weather.refreshInterval"
)

let weatherService = weatherServiceSource.readOnly
let weatherReport = weatherReportSource.readOnly
let heatAdvisory = heatAdvisorySource.readOnly
let currentZipCode = currentZipSource.readOnly
let weatherLoadStatus = weatherLoadStatusSource.readOnly
let refreshInterval = refreshIntervalSource.readOnly

let isSunny = CogBox<Bool, ZipCode>(
  { c, zip in
    switch c[weatherReport[zip]]?.kind {
    case .clear, .partlyCloudy: true
    default: false
    }
  },
  name: "weather.isSunny"
)

let isNiceOutside = CogBox<Bool, ZipCode>(
  { c, zip in
    guard let report = c[weatherReport[zip]] else { return false }
    guard c[isSunny[zip]] else { return false }
    return report.temperatureF > 60
      && report.temperatureF < 90
      && !c[heatAdvisory[zip]]
  },
  name: "weather.isNice"
)

let isNiceOutsideHere = Cog<Bool>(
  { c in
    guard let zip = c[currentZipCode] else { return false }
    return c[isNiceOutside[zip]]
  },
  name: "weather.isNiceHere"
)

let receivesHourlyUpdates = CogBox<Bool, ZipCode>(
  { c, zip in
    c[refreshInterval] != nil && c[currentZipCode] == zip
  },
  name: "weather.receivesHourlyUpdates"
)

extension Cogtext {
  func checkWeather(_ zip: ZipCode) async throws {
    guard peek(weatherLoadStatus[zip]) != .refreshing else { return }

    commit("weather.refreshStarted") { c in
      c[weatherLoadStatusSource[zip]] = .refreshing
    }

    let service = peek(weatherService)
    do {
      async let report = service.weather(for: zip)
      async let advisories = service.advisories(for: zip)
      let (nextReport, nextAdvisories) = try await (report, advisories)

      commit("weather.check") { c in
        c[weatherReportSource[zip]] = nextReport
        c[heatAdvisorySource[zip]] = nextAdvisories.contains(.heat)
        c[weatherLoadStatusSource[zip]] = .idle
      }
    } catch let cancellation as CancellationError {
      commit("weather.refreshCancelled") { c in
        c[weatherLoadStatusSource[zip]] = .idle
      }
      throw cancellation
    } catch {
      commit("weather.refreshFailed") { c in
        c[weatherLoadStatusSource[zip]] = .failed
      }
      throw error
    }
  }

  func useCurrentLocation(_ zip: ZipCode?) {
    commit("weather.useCurrentLocation") { c in
      c[currentZipSource] = zip
    }
  }

  var currentZipBinding: Binding<ZipCode?> {
    binding(
      for: currentZipCode,
      name: "weather.useCurrentLocation"
    ) { c, zip in
      c[currentZipSource] = zip
    }
  }

  func useRefreshInterval(_ interval: Duration?) {
    commit("weather.useRefreshInterval") { c in
      c[refreshIntervalSource] = interval
    }
  }
}

#if DEBUG
extension Cogtext {
  func seedWeatherService(_ service: WeatherService) {
    seed(weatherServiceSource, to: service)
  }

  func seedCurrentZip(_ zip: ZipCode?) {
    seed(currentZipSource, to: zip)
  }

  func seedWeather(_ report: Weather?, heatAdvisory: Bool, zip: ZipCode) {
    seed(weatherReportSource[zip], to: report)
    seed(heatAdvisorySource[zip], to: heatAdvisory)
  }

  func stubWeather(_ report: Weather?, heatAdvisory: Bool, zip: ZipCode) {
    commit("weather.stub") { c in
      c[weatherReportSource[zip]] = report
      c[heatAdvisorySource[zip]] = heatAdvisory
    }
  }
}
#endif
