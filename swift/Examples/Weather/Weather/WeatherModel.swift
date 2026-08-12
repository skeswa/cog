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

  var displayName: String {
    state.isEmpty ? city : "\(city), \(state) · \(rawValue)"
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

  static let live = Self(
    weather: { zip in
      switch zip {
      case .newYork: Weather(kind: .clear, temperatureF: 75)
      case .sanFrancisco: Weather(kind: .partlyCloudy, temperatureF: 68)
      case .seattle: Weather(kind: .cloudy, temperatureF: 60)
      default: Weather(kind: .clear, temperatureF: 72)
      }
    },
    advisories: { _ in [] }
  )
}
