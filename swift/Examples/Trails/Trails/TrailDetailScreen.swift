import Cog
import SwiftUI

/// One trail's detail, reachable by push, search, bookmark, URL, or journal.
///
/// The screen reads its own keyed saved flag and hike count. Bookmarking or
/// logging this trail re-renders this screen
/// without touching any other detail screen that may sit on another tab's
/// stack.
struct TrailDetailScreen: View {
  /// The trail this screen shows.
  let trailID: TrailID

  /// Renders the trail, or a soft failure for a stale identity.
  var body: some View {
    if let trail = TrailCatalog.trail(trailID) {
      TrailDetailContent(trail: trail)
    } else {
      ContentUnavailableView(
        "Trail not found",
        systemImage: "questionmark.circle",
        description: Text("This link points at a trail that is not in the catalog.")
      )
      .navigationTitle("Not found")
    }
  }
}

/// The resolved detail body for a known catalog trail.
private struct TrailDetailContent: View {
  /// Runtime resolved directly by this screen boundary.
  @Environment(\.cogs) private var cogs
  /// The catalog entry being shown.
  let trail: Trail

  /// Renders stats, actions, related trails, and the trail's own URL.
  var body: some View {
    let isTrailSaved = cogs[isTrailSavedCogs[trail.id]]
    let hikeCount = cogs[hikeCountCogs[trail.id]]
    let selectedTab = cogs[selectedTabCog]

    List {
      Section {
        LabeledContent("Distance", value: "\(trail.miles.formatted()) miles")
        LabeledContent("Difficulty") {
          Label(trail.difficulty.label, systemImage: trail.difficulty.symbol)
        }
        LabeledContent("Hikes logged", value: "\(hikeCount)")
      } header: {
        Text(trail.blurb)
          .textCase(nil)
      }

      Section {
        Button {
          cogs.present(.hikeLogger(trail.id))
        } label: {
          Label("Log a hike", systemImage: "pencil.line")
        }

        if selectedTab != .explore {
          Button {
            cogs.showTrailInExplore(trail.id)
          } label: {
            Label("Show in Explore", systemImage: "map")
          }
        }
      } footer: {
        if selectedTab != .explore {
          Text("Show in Explore switches tabs and rebuilds that stack in one turn.")
        }
      }

      relatedTrails

      Section("Deep link") {
        ShareLink(item: TrailDeepLink.trail(trail.id).url) {
          Label(TrailDeepLink.trail(trail.id).url.absoluteString, systemImage: "link")
            .font(.callout.monospaced())
        }
      }
    }
    .navigationTitle(trail.name)
    .navigationBarTitleDisplayMode(.large)
    .toolbar {
      Button {
        cogs.toggleSavedTrail(trail.id)
      } label: {
        Image(systemName: isTrailSaved ? "bookmark.fill" : "bookmark")
      }
      .accessibilityLabel(isTrailSaved ? "Remove bookmark" : "Save trail")
    }
  }

  /// Other trails in the same region, pushable to arbitrary depth.
  @ViewBuilder
  private var relatedTrails: some View {
    let neighbors = TrailCatalog.trails(in: trail.regionID).filter { $0.id != trail.id }

    if !neighbors.isEmpty {
      Section("More in this region") {
        ForEach(neighbors) { neighbor in
          NavigationLink(value: TrailRoute.trail(neighbor.id)) {
            TrailRow(trailID: neighbor.id)
          }
        }
      }
    }
  }
}
