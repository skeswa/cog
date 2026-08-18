import Cog
import MapKit
import SwiftUI

struct WeatherDashboard: View {
  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 16) {
          BackgroundUpdatesCard()
          WeatherMapCard()

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

/// Frames the selected weather location without mirroring it outside Cog.
///
/// `MapCameraPosition` is ephemeral platform UI state. While this view is
/// visible, its structured `.task` applies the current exported destination
/// and every later change. SwiftUI cancels that task on disappearance, ending
/// the sequence and releasing its graph lease with the screen that needed it.
struct WeatherMapCard: View {
  /// The singular graph inherited from ``WeatherApp``.
  @Environment(\.cogs) private var cogs

  /// Camera state owned by the platform control rather than the domain graph.
  @State private var camera: MapCameraPosition = .automatic

  #if DEBUG
  /// Optional observation of an applied camera value for the simulator proof.
  ///
  /// The production call site uses the default `nil`; release builds carry no
  /// callback storage or invocation.
  private let didFocus: (@MainActor (WeatherMapLocation) -> Void)?

  /// Creates the real map, optionally exposing its camera boundary to a test.
  init(didFocus: (@MainActor (WeatherMapLocation) -> Void)? = nil) {
    self.didFocus = didFocus
  }
  #else
  /// Creates the production map without a debug camera callback.
  init() {}
  #endif

  /// Shows every canned city and follows the current refresh selection.
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("Selected city", systemImage: "map")
        .font(.headline)

      Map(position: $camera) {
        ForEach(WeatherMapLocation.examples, id: \.zip) { location in
          Marker(location.zip.city, coordinate: location.coordinate)
        }
      }
      .frame(height: 180)
      .clipShape(RoundedRectangle(cornerRadius: 16))
      .accessibilityLabel("Weather locations")
    }
    .padding(16)
    .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 20))
    .task {
      for await location in cogs.values(of: weatherMapLocationCog) {
        guard let location else {
          camera = .automatic
          continue
        }
        withAnimation { camera = .region(location.region) }
        #if DEBUG
        didFocus?(location)
        #endif
      }
    }
  }
}

extension WeatherMapLocation {
  /// Core Location coordinate used by the map marker.
  fileprivate var coordinate: CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
  }

  /// A city-scale region applied to the map camera.
  fileprivate var region: MKCoordinateRegion {
    MKCoordinateRegion(
      center: coordinate,
      span: MKCoordinateSpan(latitudeDelta: 0.18, longitudeDelta: 0.18)
    )
  }
}

private struct BackgroundUpdatesCard: View {
  @Environment(\.cogs) private var cogs

  var body: some View {
    let refreshInterval = cogs[refreshIntervalCog]
    let cadence = refreshInterval?.cadenceDescription

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
