import Cog
import SwiftUI

/// The tabbed shell whose every navigation container is driven by graph state.
///
/// The tab selection, all four stacks, and the sheet read from Cog through
/// bindings, so a deep link's single turn moves the whole interface at once,
/// and system gestures write back into the same sources they read.
struct TrailsRoot: View {
  /// Singular graph inherited from ``TrailsApp``.
  @Environment(\.cogs) private var cogs

  /// Renders the tab bar, the per-tab stacks, the modal layer, and the
  /// URL entry point.
  var body: some View {
    let savedTrailCount = cogs[savedTrailCountCog]

    TabView(selection: cogs.selectedTabBinding) {
      ForEach(TrailTab.allCases) { tab in
        TrailTabStack(tab: tab)
          .tabItem { Label(tab.label, systemImage: tab.symbol) }
          .badge(tab == .saved ? savedTrailCount : 0)
          .tag(tab)
      }
    }
    .tint(TrailsTheme.accent)
    .sheet(item: cogs.presentedSheetBinding) { sheet in
      TrailSheetHost(sheet: sheet)
    }
    .onOpenURL { url in
      cogs.open(url: url)
    }
  }
}

/// One tab's `NavigationStack`, bound to that tab's own path cog.
///
/// Each tab owning its own stack is what lets a push on Explore leave the
/// other three containers untouched: this view's body reads exactly one
/// keyed path value.
private struct TrailTabStack: View {
  /// Runtime resolved directly by this navigation container.
  @Environment(\.cogs) private var cogs
  /// The tab whose stack this container renders.
  let tab: TrailTab

  /// Hosts the tab root and resolves every pushed route to its screen.
  var body: some View {
    NavigationStack(path: cogs.tabPathBinding(for: tab)) {
      tabRoot
        .navigationDestination(for: TrailRoute.self) { route in
          switch route {
          case .region(let regionID):
            RegionScreen(regionID: regionID)
          case .trail(let trailID):
            TrailDetailScreen(trailID: trailID)
          }
        }
    }
  }

  /// The root screen for this container's tab.
  @ViewBuilder
  private var tabRoot: some View {
    switch tab {
    case .explore: ExploreScreen()
    case .search: SearchScreen()
    case .saved: SavedScreen()
    case .journal: JournalScreen()
    }
  }
}

/// Resolves the presented sheet value to its screen.
private struct TrailSheetHost: View {
  /// The sheet case being presented.
  let sheet: TrailSheet

  /// Hosts the sheet content with a medium starting detent.
  var body: some View {
    switch sheet {
    case .hikeLogger(let trailID):
      HikeLoggerSheet(trailID: trailID)
        .presentationDetents([.medium, .large])
    }
  }
}

/// Shared visual constants for the Trails example.
enum TrailsTheme {
  /// Deep conifer green used for tints and emphasis.
  static let accent = Color(red: 0.11, green: 0.42, blue: 0.29)
  /// Adaptive raised surface for cards and footers.
  static let card = Color(uiColor: .secondarySystemGroupedBackground)
}
