import Cog
import SwiftUI

struct WeatherDashboard: View {
  @Environment(\.cogs) private var cogs

  private static let zipCodes: [ZipCode] = [
    .newYork,
    .sanFrancisco,
    .seattle,
  ]

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          Picker("Current ZIP", selection: cogs.currentZipBinding) {
            Text("Not selected")
              .tag(ZipCode?.none)

            ForEach(Self.zipCodes) { zip in
              Text(zip.description)
                .tag(Optional(zip))
            }
          }
          .pickerStyle(.menu)

          LazyVStack(spacing: 16) {
            ForEach(Self.zipCodes) { zip in
              WeatherCard(zip: zip)
            }
          }
        }
        .padding()
      }
      .navigationTitle("Weather")
    }
  }
}
