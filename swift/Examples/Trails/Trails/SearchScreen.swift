import Cog
import SwiftUI

/// The Search tab's root: query-driven results with their own stack.
///
/// The field binds straight to the graph's query source, and results are an
/// automatic value over it. A `cog-trails://search?q=…` deep link writes the
/// same source in its navigation turn, so an arriving link and a typing user
/// exercise identical state.
struct SearchScreen: View {
  /// Runtime resolved directly by this screen boundary.
  @Environment(\.cogs) private var cogs

  /// Renders the searchable result list and its empty states.
  var body: some View {
    let searchQuery = cogs[searchQueryCog]
    let searchResults = cogs[searchResultsCog]

    List {
      ForEach(searchResults) { trailID in
        NavigationLink(value: TrailRoute.trail(trailID)) {
          TrailRow(trailID: trailID, showsRegion: true)
        }
      }
    }
    .overlay {
      if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        ContentUnavailableView(
          "Search the catalog",
          systemImage: "magnifyingglass",
          description: Text("Find trails by name or region — try “falls” or “coast”.")
        )
      } else if searchResults.isEmpty {
        ContentUnavailableView.search(text: searchQuery)
      }
    }
    .searchable(text: cogs.searchQueryBinding, prompt: "Trail or region")
    .navigationTitle("Search")
  }
}
