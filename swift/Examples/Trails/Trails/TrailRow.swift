import Cog
import SwiftUI

/// One trail row shared by the region, search, and saved lists.
///
/// The row reads its own keyed saved flag, so bookmarking one trail
/// re-renders exactly the rows showing that trail and no others.
struct TrailRow: View {
  /// Runtime resolved directly by this row boundary.
  @Environment(\.cogs) private var cogs
  /// The trail this row shows.
  let trailID: TrailID
  /// Whether to include the region name under the trail name.
  var showsRegion = false

  /// Renders the trail's name, stats, and saved indicator.
  var body: some View {
    let isTrailSaved = cogs[isTrailSavedCogs[trailID]]

    if let trail = TrailCatalog.trail(trailID) {
      HStack(spacing: 12) {
        Image(systemName: trail.difficulty.symbol)
          .font(.headline)
          .foregroundStyle(TrailsTheme.accent)
          .frame(width: 30)
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 2) {
          Text(trail.name)
            .font(.body.weight(.medium))

          Text(rowSubtitle(for: trail))
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Spacer()

        if isTrailSaved {
          Image(systemName: "bookmark.fill")
            .font(.caption)
            .foregroundStyle(TrailsTheme.accent)
            .accessibilityLabel("Saved")
        }
      }
      .padding(.vertical, 2)
    }
  }

  /// Miles, difficulty, and optionally the region, as one caption line.
  ///
  /// - Parameter trail: The catalog entry backing this row.
  private func rowSubtitle(for trail: Trail) -> String {
    let stats = "\(trail.miles.formatted()) mi · \(trail.difficulty.label)"
    guard showsRegion, let region = TrailCatalog.region(trail.regionID) else { return stats }
    return "\(region.name) · \(stats)"
  }
}
