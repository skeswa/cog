import Cog
import SwiftUI

/// The Saved tab's root: bookmarked trails with their own stack.
///
/// Pushing a saved trail here builds a stack on the Saved tab, independent
/// of Explore's. The row's context menu jumps to the same trail on Explore
/// through the cross-tab operation instead, which rebuilds that other stack
/// in one turn.
struct SavedScreen: View {
  /// Runtime resolved directly by this screen boundary.
  @Environment(\.cogs) private var cogs

  /// Renders the bookmark list, or an empty state pointing at Explore.
  var body: some View {
    let savedTrailIDs = cogs[savedTrailIDsCog]

    List {
      ForEach(savedTrailIDs) { trailID in
        NavigationLink(value: TrailRoute.trail(trailID)) {
          TrailRow(trailID: trailID, showsRegion: true)
        }
        .swipeActions {
          Button("Remove", systemImage: "bookmark.slash") {
            cogs.toggleSavedTrail(trailID)
          }
          .tint(.red)
        }
        .contextMenu {
          Button("Show in Explore", systemImage: "map") {
            cogs.showTrailInExplore(trailID)
          }
        }
      }
    }
    .overlay {
      if savedTrailIDs.isEmpty {
        ContentUnavailableView(
          "No saved trails",
          systemImage: "bookmark",
          description: Text("Bookmark a trail from its detail screen to collect it here.")
        )
      }
    }
    .navigationTitle("Saved")
  }
}
