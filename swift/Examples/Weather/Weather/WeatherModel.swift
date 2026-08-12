import Foundation

nonisolated struct ZipCode: RawRepresentable, Hashable, Identifiable, Sendable {
  let rawValue: String

  var id: Self { self }

  static let newYork = Self(rawValue: "10001")
  static let sanFrancisco = Self(rawValue: "94105")
  static let seattle = Self(rawValue: "98101")

  static let examples: [Self] = [.newYork, .sanFrancisco, .seattle]

  var city: String {
    switch self {
    case .newYork: "New York"
    case .sanFrancisco: "San Francisco"
    case .seattle: "Seattle"
    default: "ZIP \(rawValue)"
    }
  }

  var state: String {
    switch self {
    case .newYork: "NY"
    case .sanFrancisco: "CA"
    case .seattle: "WA"
    default: ""
    }
  }

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
  var description: String { rawValue }
}

nonisolated struct Weather: Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case clear
    case partlyCloudy
    case cloudy
    case rain
    case snow
  }

  let kind: Kind
  let temperatureF: Double
}

nonisolated enum WeatherAdvisory: Equatable, Sendable {
  case heat
}

nonisolated enum WeatherLoadStatus: Equatable, Sendable {
  case idle
  case refreshing
  case failed
}

nonisolated struct WeatherService: Sendable {
  private let weatherRequest: @Sendable (ZipCode) async throws -> Weather
  private let advisoryRequest: @Sendable (ZipCode) async throws -> [WeatherAdvisory]

  init(
    weather: @escaping @Sendable (ZipCode) async throws -> Weather,
    advisories: @escaping @Sendable (ZipCode) async throws -> [WeatherAdvisory]
  ) {
    weatherRequest = weather
    advisoryRequest = advisories
  }

  func weather(for zip: ZipCode) async throws -> Weather {
    try await weatherRequest(zip)
  }

  func advisories(for zip: ZipCode) async throws -> [WeatherAdvisory] {
    try await advisoryRequest(zip)
  }

  /// The canned feed the app runs on.
  ///
  /// `latency` stands in for a network round trip. Tests pass `.zero` to walk
  /// the whole rotation without waiting through it.
  static func demo(latency: Duration = .seconds(1)) -> Self {
    let feed = DemoWeatherFeed()
    return Self(
      weather: { zip in
        try await Task.sleep(for: latency)
        return await feed.reading(for: zip).weather
      },
      advisories: { zip in
        try await Task.sleep(for: latency)
        return await feed.reading(for: zip).advisories
      }
    )
  }

  static let live = demo()
}

/// One day of canned demo data: a forecast and the advisories in force with it.
nonisolated struct WeatherReading: Equatable, Sendable {
  let weather: Weather
  let advisories: [WeatherAdvisory]

  init(_ kind: Weather.Kind, _ temperatureF: Double, advisories: [WeatherAdvisory] = []) {
    weather = Weather(kind: kind, temperatureF: temperatureF)
    self.advisories = advisories
  }
}

/// Vends the demo's canned forecasts.
///
/// One refresh makes two requests — weather and advisories — and they have to
/// describe the same day, or a mild afternoon arrives carrying a heat
/// advisory. Each reading is therefore served exactly twice: whichever request
/// arrives first starts the day, and the other joins it. A refresh cancelled
/// between the two leaves the pairing half a day out, which the next refresh
/// absorbs.
private actor DemoWeatherFeed {
  private var servedByZip: [ZipCode: Int] = [:]

  func reading(for zip: ZipCode) -> WeatherReading {
    let served = servedByZip[zip, default: 0]
    servedByZip[zip] = served + 1

    let readings = Self.readings(for: zip)
    return readings[(served / 2) % readings.count]
  }

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
