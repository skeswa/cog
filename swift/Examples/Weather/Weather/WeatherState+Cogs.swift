import Cog

// Weather's whole state layer: the sources, the automatic values, and
// the ops that write them.
//
// Everything here is main-actor-isolated without saying so. The target builds
// with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (Config/Shared.xcconfig),
// which is what makes an unannotated global safe to hold a `Cog.Manual`, and
// what puts these declarations on the same actor as the graph they name.

/// The request boundary selected by every keyed forecast.
private let _weatherServiceCog = Cog<WeatherService>.Manual { .live }
/// The optional ZIP whose card receives periodic refreshes and nice-weather alerts.
private let _currentZipCodeCog = Cog<ZipCode?>.Manual { nil }
/// How often background refresh runs, or `nil` while none is installed.
///
/// `WeatherMechanism.operate` publishes its own interval here. The cadence is
/// configuration rather than weather, but the cards describe it, and a screen
/// that repeats the literal instead is a second source of the same fact — one
/// that goes quietly wrong the moment the interval changes.
private let _refreshIntervalCog = Cog<Duration?>.Manual { nil }

/// Read-only service capability used by the async selector.
let weatherServiceCog = _weatherServiceCog.readOnly
/// Read-only selection shared by the picker, hourly loop, and alert reaction.
let currentZipCodeCog = _currentZipCodeCog.readOnly
/// The cadence actually installed by ``WeatherMechanism``.
let refreshIntervalCog = _refreshIntervalCog.readOnly

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
/// The selector synchronously captures the current service as a Cog dependency.
/// The returned work runs away from the MainActor, while Cog brings its pending,
/// success, and failure status back to the graph as ordered turns.
let weatherForecastCogs = CogBox<WeatherReading?, ZipCode>.Async(default: nil) { c, zip in
  let weatherService = c[weatherServiceCog]
  return .run { @concurrent in
    try await weatherService.forecast(for: zip)
  }
}

/// Whether the latest successful reading for a ZIP depicts a sunny condition.
///
/// The plain value read keeps this automatic value stable across reload pending
/// and failure status; it changes only when the accepted reading does.
let isSunnyCogs = CogBox<Bool, ZipCode> { c, zip in
  let weatherForecast = c[weatherForecastCogs[zip]]
  return switch weatherForecast?.weather.kind {
  case .clear, .partlyCloudy: true
  default: false
  }
}

/// Whether the latest accepted weather and advisories are suitable for being outside.
///
/// This keyed automatic value is shared by cards and the location-specific reaction,
/// so the app has one definition of "nice" and equality gates both consumers.
let isNiceOutsideCogs = CogBox<Bool, ZipCode> { c, zip in
  guard let weatherForecast = c[weatherForecastCogs[zip]] else { return false }
  let isSunny = c[isSunnyCogs[zip]]
  guard isSunny else { return false }
  return weatherForecast.weather.temperatureF > 60
    && weatherForecast.weather.temperatureF < 90
    && !weatherForecast.advisories.contains(.heat)
}

/// The nice-weather value for the currently selected location.
///
/// Changing the selection replaces the keyed dependency captured by this cog;
/// `nil` deliberately makes the reaction inactive without demanding a forecast.
let isNiceOutsideHereCog = Cog<Bool> { c in
  guard let currentZipCode = c[currentZipCodeCog] else { return false }
  let isNiceOutside = c[isNiceOutsideCogs[currentZipCode]]
  return isNiceOutside
}

/// Whether one card is the currently selected target of an installed refresh loop.
let receivesHourlyUpdatesCogs = CogBox<Bool, ZipCode> { c, zip in
  let refreshInterval = c[refreshIntervalCog]
  let currentZipCode = c[currentZipCodeCog]
  return refreshInterval != nil && currentZipCode == zip
}

/// The automatic map destination for the currently selected refresh location.
///
/// This is genuinely automatic state rather than a bundle of reads: it maps a domain
/// selection to the coordinates a platform camera needs. A visible map leases
/// it through `values(of:)`; when that view disappears, normal observed
/// lifetime can release the otherwise unused projection.
let weatherMapLocationCog = Cog<WeatherMapLocation?> { c in
  guard let currentZipCode = c[currentZipCodeCog] else { return nil }
  return WeatherMapLocation(zip: currentZipCode)
}

extension CogOps {
  /// Selects the ZIP used by the alert reaction and periodic refresh loop.
  ///
  /// One definition serves both capabilities: views and app code call it on
  /// `cogs`, and the weather mechanism could call it on its controller.
  func selectCurrentLocation(_ zip: ZipCode?) {
    turn(_currentZipCodeCog, to: zip)
  }

  /// Publishes the cadence owned by the assembly-registered mechanism.
  func setRefreshInterval(_ interval: Duration?) {
    turn(_refreshIntervalCog, to: interval)
  }

  /// Demands a fresh forecast for one ZIP.
  ///
  /// `refresh` is a primitive, like `turn`: it is how the graph is asked to
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
