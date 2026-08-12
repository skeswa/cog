import Cog
import SwiftUI

struct WeatherCard: View {
  @Environment(\.cogs) private var cogs

  let zip: ZipCode

  var body: some View {
    WeatherCardContent(cogs: cogs, zip: zip)
  }
}

/// The environment-free card body used by deterministic render tests.
struct WeatherCardContent: View {
  let cogs: Cogtext
  let zip: ZipCode

  var body: some View {
    let report = cogs.get(weatherReport[zip])
    let nice = cogs.get(isNiceOutside[zip])

    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 4) {
          Text("ZIP \(zip.description)")
            .font(.headline)

          Text(report?.kind.label ?? "Waiting for a report")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }

        Spacer()

        Image(systemName: report?.kind.symbolName ?? "cloud")
          .font(.title)
          .foregroundStyle(nice ? .green : .secondary)
          .accessibilityHidden(true)
      }

      Text(report.map { "\(Int($0.temperatureF.rounded()))°F" } ?? "—")
        .font(.system(.largeTitle, design: .rounded, weight: .semibold))
        .contentTransition(.numericText())

      Label(
        nice ? "Go outside!" : "Stay in.",
        systemImage: nice ? "figure.walk" : "house"
      )
      .font(.subheadline.weight(.medium))
      .foregroundStyle(nice ? .green : .secondary)

      Button("Check the weather", systemImage: "arrow.clockwise") {
        Task {
          try? await cogs.checkWeather(zip)
        }
      }
      .buttonStyle(.borderedProminent)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(20)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
  }
}

extension Weather.Kind {
  fileprivate var label: String {
    switch self {
    case .clear: "Clear"
    case .partlyCloudy: "Partly cloudy"
    case .cloudy: "Cloudy"
    case .rain: "Rain"
    case .snow: "Snow"
    }
  }

  fileprivate var symbolName: String {
    switch self {
    case .clear: "sun.max.fill"
    case .partlyCloudy: "cloud.sun.fill"
    case .cloudy: "cloud.fill"
    case .rain: "cloud.rain.fill"
    case .snow: "cloud.snow.fill"
    }
  }
}
