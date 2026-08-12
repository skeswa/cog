import Cog
import SwiftUI

struct WeatherCard: View {
  @Environment(\.cogs) private var cogs

  let zip: ZipCode

  var body: some View {
    WeatherCardContent(cogs: cogs, zip: zip)
  }
}

/// The card body, taking its context explicitly rather than from the
/// environment.
///
/// Every tracked read a card makes happens here, and the render tests evaluate
/// this `body` directly instead of hosting it. An unhosted view resolves no
/// environment, so `@Environment(\.cogs)` would trap; taking the context as a
/// parameter is what lets those tests count renders without a host. Views that
/// only act on the graph rather than read it — the refresh button below — have
/// no such constraint and read the environment normally.
struct WeatherCardContent: View {
  let cogs: Cogtext
  let zip: ZipCode
  #if DEBUG
  var renderProbe: (@MainActor (WeatherCardSnapshot) -> Void)? = nil
  #endif

  var body: some View {
    let report = cogs[weatherReport[zip]]
    let nice = cogs[isNiceOutside[zip]]
    let status = cogs[weatherLoadStatus[zip]]
    let receivesUpdates = cogs[receivesHourlyUpdates[zip]]
    let cadence = cogs[refreshInterval]?.shortCadenceDescription
    #if DEBUG
    let _ = renderProbe?(WeatherCardSnapshot(zip: zip, report: report, isNice: nice))
    #endif

    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text(zip.city)
            .font(.title3.bold())

          Text(zip.state.isEmpty ? zip.description : "\(zip.state) · \(zip.description)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Spacer()

        if receivesUpdates, let cadence {
          Label("Every \(cadence)", systemImage: "timer")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(.tint.opacity(0.11), in: Capsule())
            .accessibilityAddTraits(.isSelected)
        }
      }

      if let report {
        HStack(alignment: .center) {
          Text("\(Int(report.temperatureF.rounded()))°")
            .font(.system(size: 48, weight: .semibold, design: .rounded))
            .contentTransition(.numericText())
            .accessibilityLabel(
              "\(Int(report.temperatureF.rounded())) degrees Fahrenheit"
            )

          Spacer()

          VStack(alignment: .trailing, spacing: 5) {
            Image(systemName: report.kind.symbolName)
              .font(.title)
              .foregroundStyle(report.kind.tint)
              .accessibilityHidden(true)

            Text(report.kind.label)
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
        }

        Divider()

        HStack(spacing: 12) {
          Label(
            nice ? "Good outdoor weather" : "Better indoors",
            systemImage: nice ? "figure.walk" : "house"
          )
          .font(.subheadline.weight(.medium))

          Spacer(minLength: 8)

          RefreshButton(zip: zip, status: status)
        }

        if status == .failed {
          Label(
            "Couldn't update. Your last forecast is still shown.",
            systemImage: "exclamationmark.circle"
          )
          .font(.caption)
          .foregroundStyle(.red)
        }
      } else {
        EmptyForecast(zip: zip, status: status)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(18)
    .background(
      Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 20)
        .stroke(receivesUpdates ? Color.accentColor.opacity(0.55) : .clear, lineWidth: 1.5)
    }
    .accessibilityElement(children: .contain)
  }
}

private struct EmptyForecast: View {
  let zip: ZipCode
  let status: WeatherLoadStatus

  var body: some View {
    VStack(spacing: 12) {
      if status == .refreshing {
        ProgressView()
          .controlSize(.large)
        Text("Loading forecast…")
          .font(.subheadline.weight(.medium))
      } else {
        Image(systemName: status == .failed ? "exclamationmark.circle" : "cloud.sun")
          .font(.title)
          .foregroundStyle(status == .failed ? .red : .secondary)
          .accessibilityHidden(true)

        Text(status == .failed ? "Couldn't update" : "No forecast yet")
          .font(.subheadline.weight(.medium))

        Text(
          status == .failed
            ? "Check your connection and try again." : "Refresh to check current conditions."
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        RefreshButton(zip: zip, status: status)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 12)
    .multilineTextAlignment(.center)
  }
}

private struct RefreshButton: View {
  @Environment(\.cogs) private var cogs

  let zip: ZipCode
  let status: WeatherLoadStatus

  var body: some View {
    Button {
      Task {
        try? await cogs.checkWeather(zip)
      }
    } label: {
      if status == .refreshing {
        HStack(spacing: 6) {
          ProgressView()
          Text("Updating")
        }
      } else {
        Label(status == .failed ? "Try again" : "Refresh", systemImage: "arrow.clockwise")
      }
    }
    .buttonStyle(.bordered)
    .disabled(status == .refreshing)
    .accessibilityLabel(
      status == .failed ? "Try updating \(zip.city) again" : "Refresh \(zip.city) forecast"
    )
  }
}

#if DEBUG
nonisolated struct WeatherCardSnapshot: Equatable, Sendable {
  let zip: ZipCode
  let report: Weather?
  let isNice: Bool
}
#endif

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

  fileprivate var tint: Color {
    switch self {
    case .clear: .orange
    case .partlyCloudy: .blue
    case .cloudy: .gray
    case .rain: .blue
    case .snow: .cyan
    }
  }
}
