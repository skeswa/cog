import Cog
import SwiftUI

/// Renders one keyed forecast from the app context inherited through SwiftUI.
///
/// Every view that interacts with Cog resolves `Cogs` for itself. Its parent
/// passes only the card's domain identity, never the runtime.
struct WeatherCard: View {
  /// The singular graph inherited from `WeatherApp`.
  @Environment(\.cogs) private var cogs

  /// The async-cog key this card observes and refreshes.
  let zip: ZipCode

  /// Renders pending, success, and failure without discarding a prior success.
  ///
  /// The card reads one total `CogStatus` value for both retained content and
  /// request chrome. Its value rests at `nil`, survives reload and failure,
  /// and its kind describes the current request without a parallel lifecycle
  /// read. SwiftUI observes only those two fields; the unused error and flags
  /// do not participate in this body's invalidation.
  /// `isNiceOutsideCogs` demonstrates a separately equality-gated derivation over
  /// the ordinary async value. All reads settle within one completed graph
  /// turn, and SwiftUI's one-shot tracking invalidates once per frame.
  var body: some View {
    // Every value this card shows, read flatly and bound to a domain local.
    // They come from one settled turn because they are read in one body, so
    // the card can never render a torn pair — and each read registers on its
    // own, so an unrelated ZIP's turn invalidates nothing here.
    let weatherForecast = cogs.status[weatherForecastCogs[zip]]
    let report = weatherForecast.value?.weather
    let isNiceOutside = cogs[isNiceOutsideCogs[zip]]
    let receivesHourlyUpdates = cogs[receivesHourlyUpdatesCogs[zip]]
    let refreshInterval = cogs[refreshIntervalCog]
    let cadence = refreshInterval?.shortCadenceDescription
    let loadStatus = WeatherLoadStatus(weatherForecast)

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

        if receivesHourlyUpdates, let cadence = cadence {
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
            isNiceOutside ? "Good outdoor weather" : "Better indoors",
            systemImage: isNiceOutside ? "figure.walk" : "house"
          )
          .font(.subheadline.weight(.medium))

          Spacer(minLength: 8)

          RefreshButton(zip: zip, status: loadStatus)
        }

        if loadStatus == .failed {
          Label(
            "Couldn't update. Your last forecast is still shown.",
            systemImage: "exclamationmark.circle"
          )
          .font(.caption)
          .foregroundStyle(.red)
        }
      } else {
        EmptyForecast(zip: zip, status: loadStatus)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(18)
    .background(
      Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 20)
        .stroke(
          receivesHourlyUpdates ? Color.accentColor.opacity(0.55) : .clear,
          lineWidth: 1.5
        )
    }
    .accessibilityElement(children: .contain)
  }
}

/// The no-success-yet presentation for initial pending or failure.
private struct EmptyForecast: View {
  /// The key used by retry copy and action.
  let zip: ZipCode
  /// The card-sized presentation mapping of the full async status.
  let status: WeatherLoadStatus

  /// Shows progress for pending and a retry path for failure or idle state.
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

/// One-shot demand for a new generation of the keyed forecast.
///
/// `refresh` returns an exact-generation handle after publishing pending and
/// starting graph-owned work. This button deliberately discards it because the
/// card already renders authoritative status; imperative callers can await
/// the handle without creating a second request state. The status disables
/// replacement while this UI action is pending; other graph callers retain
/// `.latest` replacement semantics.
private struct RefreshButton: View {
  /// The singular graph that owns the resulting generation.
  @Environment(\.cogs) private var cogs

  /// The keyed forecast to refresh.
  let zip: ZipCode
  /// The current display state used for labeling and disabling the action.
  let status: WeatherLoadStatus

  /// Demands a refresh and reflects its status in the button label.
  var body: some View {
    Button {
      cogs.refreshForecast(for: zip)
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
/// The graph-derived values captured together by one test render.
///
/// Integration tests use this value to prove a card never combines a forecast
/// from one completed turn with the derived `isNice` result from another.
nonisolated struct WeatherCardSnapshot: Equatable, Sendable {
  /// The card identity rendered.
  let zip: ZipCode
  /// The last accepted forecast visible in that render.
  let report: Weather?
  /// The suitability derivation settled in that same render.
  let isNice: Bool
}
#endif

/// Display metadata for the example's small condition vocabulary.
extension Weather.Kind {
  /// Human-readable condition copy.
  fileprivate var label: String {
    switch self {
    case .clear: "Clear"
    case .partlyCloudy: "Partly cloudy"
    case .cloudy: "Cloudy"
    case .rain: "Rain"
    case .snow: "Snow"
    }
  }

  /// SF Symbol corresponding to the condition.
  fileprivate var symbolName: String {
    switch self {
    case .clear: "sun.max.fill"
    case .partlyCloudy: "cloud.sun.fill"
    case .cloudy: "cloud.fill"
    case .rain: "cloud.rain.fill"
    case .snow: "cloud.snow.fill"
    }
  }

  /// Accent color corresponding to the condition.
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
