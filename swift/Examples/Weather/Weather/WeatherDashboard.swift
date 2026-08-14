import Cog
import SwiftUI

struct WeatherDashboard: View {
  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 16) {
          BackgroundUpdatesCard()

          HStack(alignment: .firstTextBaseline) {
            Text("Forecasts")
              .font(.title2.bold())

            Spacer()

            Text("DEMO DATA")
              .font(.caption2.weight(.bold))
              .foregroundStyle(.secondary)
              .padding(.horizontal, 8)
              .padding(.vertical, 4)
              .background(.quaternary, in: Capsule())
          }
          .padding(.top, 4)

          ForEach(ZipCode.examples) { zip in
            WeatherCard(zip: zip)
          }
        }
        .padding()
      }
      .background(Color(uiColor: .systemGroupedBackground))
      .navigationTitle("Cog Weather")
    }
  }
}

private struct BackgroundUpdatesCard: View {
  @Environment(\.cogs) private var cogs

  var body: some View {
    let cadence = cogs[refreshIntervalCog]?.cadenceDescription

    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 12) {
        Image(systemName: "clock.arrow.circlepath")
          .font(.title2.weight(.semibold))
          .foregroundStyle(.tint)
          .frame(width: 42, height: 42)
          .background(.tint.opacity(0.12), in: Circle())

        VStack(alignment: .leading, spacing: 2) {
          Text("Hourly refresh demo")
            .font(.headline)
          Text(
            cadence.map { "Each simulated hour passes in \($0)." }
              ?? "Background refresh is not running."
          )
          .font(.subheadline)
          .foregroundStyle(.secondary)
        }
      }

      Text("City to refresh")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

      Picker("City to refresh", selection: cogs.currentZipBinding) {
        Text("Off")
          .tag(ZipCode?.none)

        ForEach(ZipCode.examples) { zip in
          Text(zip.shortName)
            .accessibilityLabel(zip.city)
            .tag(Optional(zip))
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .accessibilityLabel("City to refresh")
      .accessibilityHint(
        cadence.map { "Choose one city to update every \($0)" }
          ?? "Choose one city to update in the background"
      )
    }
    .padding(16)
    .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 20))
  }
}
