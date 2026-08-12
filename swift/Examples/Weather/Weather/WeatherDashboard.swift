import Cog
import SwiftUI

struct WeatherDashboard: View {
  @Environment(\.cogs) private var cogs

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 16) {
          BackgroundUpdatesCard(cogs: cogs)

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
      .navigationTitle("Weather")
    }
  }
}

private struct BackgroundUpdatesCard: View {
  let cogs: Cogtext

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 12) {
        Image(systemName: "clock.arrow.circlepath")
          .font(.title2.weight(.semibold))
          .foregroundStyle(.tint)
          .frame(width: 42, height: 42)
          .background(.tint.opacity(0.12), in: Circle())

        VStack(alignment: .leading, spacing: 2) {
          Text("Background updates")
            .font(.headline)
          Text("Keep one city's forecast fresh every hour.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }

      HStack {
        Text("Hourly city")
          .font(.subheadline.weight(.semibold))

        Spacer()

        Picker("Hourly city", selection: cogs.currentZipBinding) {
          Text("Off")
            .tag(ZipCode?.none)

          ForEach(ZipCode.examples) { zip in
            Text(zip.displayName)
              .tag(Optional(zip))
          }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .accessibilityLabel("Hourly forecast location")
        .accessibilityHint("Choose one city to refresh automatically every hour")
      }
    }
    .padding(16)
    .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 20))
  }
}
