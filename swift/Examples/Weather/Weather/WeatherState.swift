import Cog
import SwiftUI

// Weather's whole state layer: the sources, the values derived from them, and
// the ops that write them.
//
// Everything here is main-actor-isolated without saying so. The target builds
// with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (Config/Shared.xcconfig),
// which is what makes an unannotated global safe to hold a `ManualCog`, and
// what puts these declarations on the same actor as the graph they name.

/// The injectable request boundary selected by every keyed forecast.
///
/// Production keeps the live service for the app lifetime. Tests seed a
/// controlled service before first demand, so they exercise the same async cog
/// without adding a second request-state mechanism.
private let weatherServiceSource = ManualCog<WeatherService>(
  .live,
  name: "weather.service"
)
/// The optional ZIP whose card receives periodic refreshes and nice-weather alerts.
private let currentZipSource = ManualCog<ZipCode?>(
  nil,
  name: "weather.currentZip"
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

/// Read-only service capability used by the async selector.
let weatherService = weatherServiceSource.readOnly
/// Read-only selection shared by the picker, hourly loop, and alert reaction.
let currentZipCode = currentZipSource.readOnly
/// The cadence actually installed by ``WeatherEffects``.
let refreshInterval = refreshIntervalSource.readOnly

/// The keyed forecast every card reads, resting at `nil` until a ZIP's first
/// accepted reading.
///
/// Each ZIP code gets an independent phase, dependency set, generation, and
/// task. The optional value is the whole default spelling: a value read
/// (`cogs[weatherForecast[zip]]`) is total, returning `nil` before the first
/// success and the last accepted reading afterward, while request chrome opts
/// into `cogs.phase[weatherForecast[zip]]`. The selector synchronously
/// captures the current service as a Cog dependency; replacing that service
/// in a test invalidates every demanded forecast. The returned work runs away
/// from the MainActor, while Cog brings its pending, success, and failure
/// phases back to the graph as ordered turns.
let weatherForecast = AsyncCogBox<WeatherReading?, ZipCode>(
  name: "weather.forecast"
) { c, zip in
  let service = c[weatherService]
  return .run { @concurrent in
    try await service.forecast(for: zip)
  }
}

/// Whether the latest successful reading for a ZIP depicts a sunny condition.
///
/// The plain value read keeps this derivation stable across reload pending
/// and failure phases; it changes only when the accepted reading does.
let isSunny = CogBox<Bool, ZipCode>(
  { c, zip in
    switch c[weatherForecast[zip]]?.weather.kind {
    case .clear, .partlyCloudy: true
    default: false
    }
  },
  name: "weather.isSunny"
)

/// Whether the latest accepted weather and advisories are suitable for being outside.
///
/// This keyed derivation is shared by cards and the location-specific reaction,
/// so the app has one definition of "nice" and equality gates both consumers.
let isNiceOutside = CogBox<Bool, ZipCode>(
  { c, zip in
    guard let reading = c[weatherForecast[zip]] else { return false }
    guard c[isSunny[zip]] else { return false }
    return reading.weather.temperatureF > 60
      && reading.weather.temperatureF < 90
      && !reading.advisories.contains(.heat)
  },
  name: "weather.isNice"
)

/// The nice-weather value for the currently selected location.
///
/// Changing the selection replaces the keyed dependency captured by this cog;
/// `nil` deliberately makes the reaction inactive without demanding a forecast.
let isNiceOutsideHere = Cog<Bool>(
  { c in
    guard let zip = c[currentZipCode] else { return false }
    return c[isNiceOutside[zip]]
  },
  name: "weather.isNiceHere"
)

/// Whether one card is the currently selected target of an installed refresh loop.
let receivesHourlyUpdates = CogBox<Bool, ZipCode>(
  { c, zip in
    c[refreshInterval] != nil && c[currentZipCode] == zip
  },
  name: "weather.receivesHourlyUpdates"
)

extension Cogtext {
  /// Selects the ZIP used by the alert reaction and periodic refresh loop.
  func useCurrentLocation(_ zip: ZipCode?) {
    commit("weather.useCurrentLocation") { c in
      c[currentZipSource] = zip
    }
  }

  /// A tracked SwiftUI binding to the singular current-location source.
  var currentZipBinding: Binding<ZipCode?> {
    binding(
      for: currentZipCode,
      name: "weather.useCurrentLocation"
    ) { c, zip in
      c[currentZipSource] = zip
    }
  }

  /// Publishes the cadence owned by the installed effects group.
  func useRefreshInterval(_ interval: Duration?) {
    commit("weather.useRefreshInterval") { c in
      c[refreshIntervalSource] = interval
    }
  }
}

#if DEBUG
extension Cogtext {
  /// Installs a deterministic request service before a test first demands it.
  func seedWeatherService(_ service: WeatherService) {
    seed(weatherServiceSource, to: service)
  }

  /// Selects a current ZIP before a test installs effects or renders a picker.
  func seedCurrentZip(_ zip: ZipCode?) {
    seed(currentZipSource, to: zip)
  }
}
#endif
