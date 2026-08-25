import Foundation

/// Display copy for the background-refresh cadence.
///
/// The app shortens `WeatherMechanism.hourlyRefreshInterval` to a few seconds so
/// the demo is watchable, and the screens describe that cadence in three
/// places. Formatting all three from the one installed interval keeps them
/// from disagreeing with the loop or with each other.
extension Duration {
  /// The cadence spelled out: "5 seconds", "1 hour".
  var cadenceDescription: String {
    formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
  }

  /// The cadence abbreviated for a badge: "5 sec", "1 hr".
  var shortCadenceDescription: String {
    formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
  }
}
