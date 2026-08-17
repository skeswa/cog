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
private let weatherServiceSourceCog = ManualCog<WeatherService>(
  .live,
  name: "weather.service"
)
/// The optional ZIP whose card receives periodic refreshes and nice-weather alerts.
private let currentZipSourceCog = ManualCog<ZipCode?>(
  nil,
  name: "weather.currentZip"
)
/// How often background refresh runs, or `nil` while none is installed.
///
/// `WeatherEffects.install` publishes its own interval here. The cadence is
/// configuration rather than weather, but the cards describe it, and a screen
/// that repeats the literal instead is a second source of the same fact — one
/// that goes quietly wrong the moment the interval changes.
private let refreshIntervalSourceCog = ManualCog<Duration?>(
  nil,
  name: "weather.refreshInterval"
)

/// Read-only service capability used by the async selector.
let weatherServiceCog = weatherServiceSourceCog.readOnly
/// Read-only selection shared by the picker, hourly loop, and alert reaction.
let currentZipCodeCog = currentZipSourceCog.readOnly
/// The cadence actually installed by ``WeatherEffects``.
let refreshIntervalCog = refreshIntervalSourceCog.readOnly

/// The keyed forecast every card reads, resting at `nil` until a ZIP's first
/// accepted reading.
///
/// Each ZIP code gets independent status, a dependency set, generation, and
/// task. The declaration explicitly rests at `nil`:
///
/// ```swift
/// let weatherForecast = cogs[weatherForecastCogs[zip]]
/// ```
///
/// is total, returning `nil` before the first success and the last accepted
/// reading afterward. Request chrome uses the same local name:
///
/// ```swift
/// let weatherForecast = cogs.status[weatherForecastCogs[zip]]
/// ```
///
/// The selector synchronously
/// captures the current service as a Cog dependency; replacing that service
/// in a test invalidates every demanded forecast. The returned work runs away
/// from the MainActor, while Cog brings its pending, success, and failure
/// status back to the graph as ordered turns.
let weatherForecastCogs = AsyncCogBox<WeatherReading?, ZipCode>(
  default: nil,
  name: "weather.forecast"
) { c, zip in
  let weatherService = c[weatherServiceCog]
  return .run { @concurrent in
    try await weatherService.forecast(for: zip)
  }
}

/// Whether the latest successful reading for a ZIP depicts a sunny condition.
///
/// The plain value read keeps this derivation stable across reload pending
/// and failure status; it changes only when the accepted reading does.
let isSunnyCogs = CogBox<Bool, ZipCode>(
  { c, zip in
    let weatherForecast = c[weatherForecastCogs[zip]]
    return switch weatherForecast?.weather.kind {
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
let isNiceOutsideCogs = CogBox<Bool, ZipCode>(
  { c, zip in
    guard let weatherForecast = c[weatherForecastCogs[zip]] else { return false }
    let isSunny = c[isSunnyCogs[zip]]
    guard isSunny else { return false }
    return weatherForecast.weather.temperatureF > 60
      && weatherForecast.weather.temperatureF < 90
      && !weatherForecast.advisories.contains(.heat)
  },
  name: "weather.isNice"
)

/// The nice-weather value for the currently selected location.
///
/// Changing the selection replaces the keyed dependency captured by this cog;
/// `nil` deliberately makes the reaction inactive without demanding a forecast.
let isNiceOutsideHereCog = Cog<Bool>(
  { c in
    guard let currentZipCode = c[currentZipCodeCog] else { return false }
    let isNiceOutside = c[isNiceOutsideCogs[currentZipCode]]
    return isNiceOutside
  },
  name: "weather.isNiceHere"
)

/// Whether one card is the currently selected target of an installed refresh loop.
let receivesHourlyUpdatesCogs = CogBox<Bool, ZipCode>(
  { c, zip in
    let refreshInterval = c[refreshIntervalCog]
    let currentZipCode = c[currentZipCodeCog]
    return refreshInterval != nil && currentZipCode == zip
  },
  name: "weather.receivesHourlyUpdates"
)

extension CogOps {
  /// Selects the ZIP used by the alert reaction and periodic refresh loop.
  ///
  /// One definition serves both capabilities: views and app code call it on
  /// `cogs`, and the weather mechanism could call it on its controller.
  func selectCurrentLocation(_ zip: ZipCode?) {
    commit(currentZipSourceCog, to: zip)
  }

  /// Publishes the cadence owned by the bootstrap-registered mechanism.
  func setRefreshInterval(_ interval: Duration?) {
    commit(refreshIntervalSourceCog, to: interval)
  }

  /// Demands a fresh forecast for one ZIP.
  ///
  /// `refresh` is a primitive, like `commit`: it is how the graph is asked to
  /// do something, not what this app calls the asking. Wrapping it in a named
  /// op keeps the same rule for demands as for writes — a view says what it
  /// wants in domain words, and the declaration it resolves to stays here with
  /// the rest of the state layer.
  ///
  /// - Parameter zip: Which ZIP's forecast to reload.
  func refreshForecast(for zip: ZipCode) {
    refresh(weatherForecastCogs[zip])
  }
}

extension Cogs {
  /// A tracked SwiftUI binding to the singular current-location source.
  ///
  /// The getter is a UI-boundary read, so this stays on the runtime rather
  /// than the shared op surface.
  var currentZipBinding: Binding<ZipCode?> {
    Binding(
      get: {
        let currentZipCode = self[currentZipCodeCog]
        return currentZipCode
      },
      set: { self.selectCurrentLocation($0) }
    )
  }
}

#if DEBUG
/// The narrow source capability Weather tests may seed through `CogTesting`.
let weatherServiceSeedTargetCog = weatherServiceSourceCog
/// The narrow selection capability Weather tests may seed through `CogTesting`.
let currentZipSeedTargetCog = currentZipSourceCog
#endif
