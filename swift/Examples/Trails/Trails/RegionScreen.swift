import Cog
import SwiftUI

/// One region's trail list, reachable by push or by `cog-trails://region/…`.
///
/// The screen receives only an identity, exactly as a route carries it, and
/// resolves content from the catalog. A stale identity — say, from an old
/// bookmark URL after the catalog changed — degrades to a not-found state
/// instead of crashing.
struct RegionScreen: View {
  /// The region this screen shows.
  let regionID: RegionID

  /// Renders the region's trails, or a soft failure for a stale identity.
  var body: some View {
    if let region = TrailCatalog.region(regionID) {
      List {
        Section {
          ForEach(TrailCatalog.trails(in: regionID)) { trail in
            NavigationLink(value: TrailRoute.trail(trail.id)) {
              TrailRow(trailID: trail.id)
            }
          }
        } header: {
          Text(region.tagline)
            .textCase(nil)
        }
      }
      .navigationTitle(region.name)
      .navigationBarTitleDisplayMode(.large)
    } else {
      ContentUnavailableView(
        "Region not found",
        systemImage: "questionmark.circle",
        description: Text("This link points at a region that is not in the catalog.")
      )
      .navigationTitle("Not found")
    }
  }
}
