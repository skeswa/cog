import Cog
import Foundation

/// A ZIP-code value that also supplies the demo's display metadata.
///
/// The raw string is both external request input and `AsyncCogBox` key. Value
/// identity therefore follows ZIP equality all the way from `ForEach` through
/// Cog's keyed state storage and task names.
nonisolated struct ZipCode: RawRepresentable, Hashable, Identifiable, Sendable {
  /// The postal code sent to the weather service.
  let rawValue: String

  /// Stable list identity equal to the keyed Cog identity.
  var id: Self { self }

  /// The demo's New York forecast key.
  static let newYork = Self(rawValue: "10001")
  /// The demo's San Francisco forecast key.
  static let sanFrancisco = Self(rawValue: "94105")
  /// The demo's Seattle forecast key.
  static let seattle = Self(rawValue: "98101")

  /// The cards the canned feed and dashboard present.
  static let examples: [Self] = [.newYork, .sanFrancisco, .seattle]

  /// A friendly city name, falling back to the raw ZIP for arbitrary keys.
  var city: String {
    switch self {
    case .newYork: "New York"
    case .sanFrancisco: "San Francisco"
    case .seattle: "Seattle"
    default: "ZIP \(rawValue)"
    }
  }

  /// The state abbreviation when the demo recognizes the ZIP.
  var state: String {
    switch self {
    case .newYork: "NY"
    case .sanFrancisco: "CA"
    case .seattle: "WA"
    default: ""
    }
  }

  /// A compact label used by the segmented location picker.
  var shortName: String {
    switch self {
    case .newYork: "NYC"
    case .sanFrancisco: "SF"
    case .seattle: "SEA"
    default: rawValue
    }
  }
}

extension ZipCode: CustomStringConvertible {
  /// The raw ZIP used in keyed Cog labels such as `weather.forecast[10001]`.
  var description: String { rawValue }
}

/// The visible meteorological part of one accepted reading.
nonisolated struct Weather: Equatable, Sendable {
  /// The small condition vocabulary the example can render with system symbols.
  enum Kind: Equatable, Sendable {
    /// Clear sky.
    case clear
    /// Sun with some cloud cover.
    case partlyCloudy
    /// Overcast conditions.
    case cloudy
    /// Rain.
    case rain
    /// Snow.
    case snow
  }

  /// The accepted condition.
  let kind: Kind
  /// The accepted Fahrenheit temperature.
  let temperatureF: Double
}

/// An advisory that can make otherwise pleasant weather unsuitable.
nonisolated enum WeatherAdvisory: Equatable, Sendable {
  /// Temperatures or conditions warrant a heat warning.
  case heat
}

/// The presentation state derived from a forecast's full async metadata.
///
/// This is deliberately not Cog state. The authoritative request lifecycle is
/// `CogMeta<WeatherReading?>`, read through the `meta` lens; the enum only
/// gives buttons and empty-state views concise labels for those three cases.
nonisolated enum WeatherLoadStatus: Equatable, Sendable {
  /// The latest generation succeeded.
  case idle
  /// Initial or replacement work is pending.
  case refreshing
  /// The latest generation failed, possibly with a retained prior reading.
  case failed

  /// Maps authoritative async metadata to the card's smaller display vocabulary.
  init(_ metadata: CogMeta<WeatherReading?>) {
    switch metadata {
    case .pending: self = .refreshing
    case .success: self = .idle
    case .failure: self = .failed
    }
  }
}

/// A sendable request boundary selected synchronously by `weatherForecast`.
///
/// The service contains no Cog state and owns no task. Its closure executes only
/// after the async selector returns `Work`, on the executor selected by that
/// work. Tests replace the closure before demand to control completions while
/// leaving task ownership, cancellation, and metadata publication with Cog.
nonisolated struct WeatherService: Sendable {
  /// The sendable request implementation captured by off-MainActor work.
  private let forecastRequest: @Sendable (ZipCode) async throws -> WeatherReading

  /// Creates a service from one atomic reading request.
  ///
  /// - Parameter forecast: The request for a ZIP. Throwing becomes the async
  ///   cog's failure metadata; returning becomes its success metadata.
  init(
    forecast: @escaping @Sendable (ZipCode) async throws -> WeatherReading
  ) {
    forecastRequest = forecast
  }

  /// Fetches one atomic reading for `zip`.
  ///
  /// - Parameter zip: The keyed forecast identity being refreshed.
  /// - Returns: Weather and advisories from the same service response.
  func forecast(for zip: ZipCode) async throws -> WeatherReading {
    try await forecastRequest(zip)
  }

  /// The canned feed the app runs on.
  ///
  /// `latency` stands in for a network round trip. Tests pass `.zero` to walk
  /// the whole rotation without waiting through it.
  ///
  /// - Parameter latency: Artificial cooperative delay before each response.
  /// - Returns: A service backed by an actor-isolated per-ZIP rotation.
  static func demo(latency: Duration = .seconds(1)) -> Self {
    let feed = DemoWeatherFeed()
    return Self { zip in
      try await Task.sleep(for: latency)
      return await feed.nextReading(for: zip)
    }
  }

  /// The production example service with a one-second simulated round trip.
  static let live = demo()
}

/// One day of canned demo data: a forecast and the advisories in force with it.
nonisolated struct WeatherReading: Equatable, Sendable {
  /// The condition and temperature rendered by the card.
  let weather: Weather
  /// Advisories accepted in the same generation as `weather`.
  let advisories: [WeatherAdvisory]

  /// Builds one canned atomic response.
  ///
  /// - Parameters:
  ///   - kind: The visible condition.
  ///   - temperatureF: Its Fahrenheit temperature.
  ///   - advisories: Warnings in force for the same response.
  init(_ kind: Weather.Kind, _ temperatureF: Double, advisories: [WeatherAdvisory] = []) {
    weather = Weather(kind: kind, temperatureF: temperatureF)
    self.advisories = advisories
  }
}

/// Vends one atomic reading per demo request.
///
/// Keeping the weather and its advisories in one async value means a card can
/// never combine the temperature from one request with advisories from another.
/// Cog publishes the whole reading in the generation's success turn.
private actor DemoWeatherFeed {
  /// The next canned response index, isolated independently for every ZIP.
  private var nextIndexByZip: [ZipCode: Int] = [:]

  /// Advances and returns exactly one response for `zip`.
  func nextReading(for zip: ZipCode) -> WeatherReading {
    let nextIndex = nextIndexByZip[zip, default: 0]
    nextIndexByZip[zip] = nextIndex + 1
    let readings = Self.readings(for: zip)
    return readings[nextIndex % readings.count]
  }

  /// The repeating canned response sequence for one ZIP.
  private static func readings(for zip: ZipCode) -> [WeatherReading] {
    switch zip {
    case .newYork:
      [
        WeatherReading(.clear, 75),
        WeatherReading(.partlyCloudy, 72),
        WeatherReading(.rain, 64),
        // Clear and sunny, and still no day to be outside: the advisory and
        // the temperature both push `isNiceOutside` false on their own.
        WeatherReading(.clear, 94, advisories: [.heat]),
      ]
    case .sanFrancisco:
      [
        WeatherReading(.partlyCloudy, 68),
        WeatherReading(.cloudy, 63),
        WeatherReading(.clear, 65),
        WeatherReading(.rain, 59),
      ]
    case .seattle:
      [
        WeatherReading(.cloudy, 60),
        WeatherReading(.rain, 57),
        WeatherReading(.partlyCloudy, 62),
        WeatherReading(.rain, 55),
      ]
    default:
      [WeatherReading(.clear, 72)]
    }
  }
}
