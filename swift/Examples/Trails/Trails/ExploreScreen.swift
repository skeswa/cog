import Cog
import SwiftUI

/// The Explore tab's root: the region list.
///
/// Rows push with `NavigationLink(value:)`, the idiomatic SwiftUI spelling.
/// The link appends to the bound path, the binding's setter runs the
/// `setPath` operation. The push reaches the same path cog that operations and
/// deep links write, so both paths share one source.
struct ExploreScreen: View {
  /// Renders every catalog region.
  var body: some View {
    List {
      Section {
        ForEach(TrailCatalog.regions) { region in
          NavigationLink(value: TrailRoute.region(region.id)) {
            RegionRow(region: region)
          }
        }
      } footer: {
        Text(
          "Every screen here has a URL. Try opening cog-trails://trail/mist-ridge "
            + "from Safari, or revisit any screen from the Journal tab."
        )
      }
    }
    .navigationTitle("Explore")
  }
}

/// One region row with its symbol, name, and tagline.
private struct RegionRow: View {
  /// The catalog entry backing this row.
  let region: Region

  /// Renders the region's identity line.
  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: region.symbol)
        .font(.title3)
        .foregroundStyle(TrailsTheme.accent)
        .frame(width: 34)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(region.name)
          .font(.body.weight(.medium))

        Text(region.tagline)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
  }
}
