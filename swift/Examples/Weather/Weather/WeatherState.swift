import Cog
import SwiftUI

@MainActor private let weatherServiceSource = ManualCog<WeatherService>(
  .live,
  name: "weather.service"
)
@MainActor private let weatherReportSource = ManualCogBox<Weather?, ZipCode>(
  nil,
  name: "weather.report"
)
@MainActor private let heatAdvisorySource = ManualCogBox<Bool, ZipCode>(
  false,
  name: "weather.heatAdvisory"
)
@MainActor private let currentZipSource = ManualCog<ZipCode?>(
  nil,
  name: "weather.currentZip"
)
@MainActor private let weatherLoadStatusSource = ManualCogBox<WeatherLoadStatus, ZipCode>(
  .idle,
  name: "weather.loadStatus"
)

@MainActor let weatherService = weatherServiceSource.readOnly
@MainActor let weatherReport = weatherReportSource.readOnly
@MainActor let heatAdvisory = heatAdvisorySource.readOnly
@MainActor let currentZipCode = currentZipSource.readOnly
@MainActor let weatherLoadStatus = weatherLoadStatusSource.readOnly

@MainActor let isSunny = CogBox<Bool, ZipCode>(
  { reader, zip in
    switch reader.get(weatherReport[zip])?.kind {
    case .clear, .partlyCloudy: true
    default: false
    }
  },
  name: "weather.isSunny"
)

@MainActor let isNiceOutside = CogBox<Bool, ZipCode>(
  { reader, zip in
    guard let report = reader.get(weatherReport[zip]) else { return false }
    guard reader.get(isSunny[zip]) else { return false }
    return report.temperatureF > 60
      && report.temperatureF < 90
      && !reader.get(heatAdvisory[zip])
  },
  name: "weather.isNice"
)

@MainActor let isNiceOutsideHere = Cog<Bool>(
  { reader in
    guard let zip = reader.get(currentZipCode) else { return false }
    return reader.get(isNiceOutside[zip])
  },
  name: "weather.isNiceHere"
)

@MainActor let receivesHourlyUpdates = CogBox<Bool, ZipCode>(
  { reader, zip in
    reader.get(currentZipCode) == zip
  },
  name: "weather.receivesHourlyUpdates"
)

extension Cogtext {
  func checkWeather(_ zip: ZipCode) async throws {
    guard read(weatherLoadStatus[zip]) != .refreshing else { return }

    commit("weather.refreshStarted") { writer in
      writer[weatherLoadStatusSource[zip]] = .refreshing
    }

    let service = read(weatherService)
    do {
      async let report = service.weather(for: zip)
      async let advisories = service.advisories(for: zip)
      let (nextReport, nextAdvisories) = try await (report, advisories)

      commit("weather.check") { writer in
        writer[weatherReportSource[zip]] = nextReport
        writer[heatAdvisorySource[zip]] = nextAdvisories.contains(.heat)
        writer[weatherLoadStatusSource[zip]] = .idle
      }
    } catch is CancellationError {
      commit("weather.refreshCancelled") { writer in
        writer[weatherLoadStatusSource[zip]] = .idle
      }
      throw CancellationError()
    } catch {
      commit("weather.refreshFailed") { writer in
        writer[weatherLoadStatusSource[zip]] = .failed
      }
      throw error
    }
  }

  func useCurrentLocation(_ zip: ZipCode?) {
    commit("weather.useCurrentLocation") { writer in
      writer[currentZipSource] = zip
    }
  }

  var currentZipBinding: Binding<ZipCode?> {
    binding(
      for: currentZipCode,
      name: "weather.useCurrentLocation"
    ) { writer, zip in
      writer[currentZipSource] = zip
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
    commit("weather.stub") { writer in
      writer[weatherReportSource[zip]] = report
      writer[heatAdvisorySource[zip]] = heatAdvisory
    }
  }
}
#endif
