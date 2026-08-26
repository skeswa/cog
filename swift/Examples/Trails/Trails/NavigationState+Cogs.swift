import Cog
import Foundation

// Navigation is ordinary graph state. Each fact gets its own source so the
// UI invalidates precisely: pushing on one tab notices only that tab's path,
// presenting the sheet notices no path at all, and a cross-tab deep link is
// one atomic turn rather than a sequence of router calls.

/// The selected tab.
private let _selectedTabCog = Cog<TrailTab>.Manual { .explore }
/// Each tab's navigation stack, keyed so tabs invalidate independently.
private let _tabPathCogs = CogBox<[TrailRoute], TrailTab>.Manual { [] }
/// The single presented modal layer, or `nil` when nothing is presented.
private let _presentedSheetCog = Cog<TrailSheet?>.Manual { nil }
/// Session journal of screen visits, most recent first, written only by the
/// journal mechanism's reaction.
private let _screenJournalCog = Cog<[TrailScreenVisit]>.Manual { [] }

/// Read-only selected tab.
let selectedTabCog = _selectedTabCog.readOnly
/// Read-only per-tab navigation stacks.
let tabPathCogs = _tabPathCogs.readOnly
/// Read-only presented sheet.
let presentedSheetCog = _presentedSheetCog.readOnly
/// Read-only session journal.
let screenJournalCog = _screenJournalCog.readOnly

/// The single topmost screen, derived from sheet, selected tab, and that
/// tab's path.
///
/// Nothing stores this fact; it exists only as a computation over the
/// navigation sources, so it can never disagree with them. The journal
/// mechanism watches it, and equality gating means an unrelated turn — or a
/// push on a tab that is not selected — re-notifies nobody.
let currentScreenCog = Cog<TrailScreen> { c in
  let presentedSheet = c[presentedSheetCog]
  if case .hikeLogger(let trailID) = presentedSheet {
    return .hikeLogger(trailID)
  }

  let selectedTab = c[selectedTabCog]
  let tabPath = c[tabPathCogs[selectedTab]]
  switch tabPath.last {
  case .region(let regionID): return .region(regionID)
  case .trail(let trailID): return .trail(trailID)
  case nil: return .tabRoot(selectedTab)
  }
}

/// Whether the hike logger sheet is up, gating the elapsed-time scope.
///
/// The hike-timer mechanism hangs a `whenever` scope on this cog, so the
/// ticking task exists exactly while the logger is presented — however it was
/// presented, including by deep link or restoration.
let isLoggingHikeCog = Cog<Bool> { c in
  let presentedSheet = c[presentedSheetCog]
  guard case .hikeLogger = presentedSheet else { return false }
  return true
}

extension CogOps {
  /// Selects a tab, or pops the already-selected tab to its root.
  ///
  /// The reselect-pops-to-root behavior is the standard iOS gesture, and it
  /// falls out of navigation being state: the tab binding's setter lands
  /// here, and popping is just writing an empty path.
  ///
  /// - Parameter tab: The tapped tab.
  func selectTab(_ tab: TrailTab) {
    turn { c in
      if c[_selectedTabCog] == tab {
        c[_tabPathCogs[tab]] = []
      } else {
        c[_selectedTabCog] = tab
      }
    }
  }

  /// Pushes a route onto the selected tab's stack.
  ///
  /// - Parameter route: The step to push.
  func show(_ route: TrailRoute) {
    turn { c in
      let selectedTab = c[_selectedTabCog]
      c[_tabPathCogs[selectedTab]] = c[_tabPathCogs[selectedTab]] + [route]
    }
  }

  /// Replaces one tab's whole stack; the `NavigationStack` binding's setter.
  ///
  /// System-initiated navigation — the back button, the pop gesture, and
  /// `NavigationLink(value:)` pushes — flows through here, so both roads into
  /// navigation converge on the same source. Cog's equal-write discard makes
  /// SwiftUI's redundant binding writes free.
  ///
  /// - Parameters:
  ///   - path: The tab's complete new stack.
  ///   - tab: The tab whose stack changes.
  func setPath(_ path: [TrailRoute], in tab: TrailTab) {
    turn(_tabPathCogs[tab], to: path)
  }

  /// Jumps to one trail on the Explore tab from anywhere in the app.
  ///
  /// One turn switches the tab, rebuilds Explore's stack with the trail's
  /// region beneath it, and dismisses any sheet. No observer can see a
  /// halfway state, which is the whole argument for navigation as graph
  /// state.
  ///
  /// - Parameter trailID: The trail to reveal; unknown identities do nothing.
  func showTrailInExplore(_ trailID: TrailID) {
    guard let trail = TrailCatalog.trail(trailID) else { return }
    turn { c in
      c[_selectedTabCog] = .explore
      c[_tabPathCogs[TrailTab.explore]] = [.region(trail.regionID), .trail(trailID)]
      c[_presentedSheetCog] = nil
    }
  }

  /// Presents one modal layer over the tab interface.
  ///
  /// - Parameter sheet: The sheet to present.
  func present(_ sheet: TrailSheet) {
    turn(_presentedSheetCog, to: sheet)
  }

  /// Dismisses whatever sheet is presented; safe when nothing is.
  func dismissSheet() {
    turn(_presentedSheetCog, to: nil)
  }

  /// Resolves a parsed deep link into one atomic navigation turn.
  ///
  /// Resolution consults the catalog, so a link to a trail lands with its
  /// region already on the stack beneath it — the restored back button works.
  /// Unknown identities drop the link rather than navigating to a broken
  /// screen. The search case reaches the query source in the domain state
  /// file by calling its operation inside this turn body; the nested turn
  /// joins, keeping the transition atomic across both files.
  ///
  /// - Parameter link: The parsed link to apply.
  func open(_ link: TrailDeepLink) {
    switch link {
    case .tab(let tab):
      turn { c in
        c[_selectedTabCog] = tab
        c[_presentedSheetCog] = nil
      }
    case .region(let regionID):
      guard TrailCatalog.region(regionID) != nil else { return }
      turn { c in
        c[_selectedTabCog] = .explore
        c[_tabPathCogs[TrailTab.explore]] = [.region(regionID)]
        c[_presentedSheetCog] = nil
      }
    case .trail(let trailID):
      guard let trail = TrailCatalog.trail(trailID) else { return }
      turn { c in
        c[_selectedTabCog] = .explore
        c[_tabPathCogs[TrailTab.explore]] = [.region(trail.regionID), .trail(trailID)]
        c[_presentedSheetCog] = nil
      }
    case .hikeLogger(let trailID):
      guard let trail = TrailCatalog.trail(trailID) else { return }
      turn { c in
        c[_selectedTabCog] = .explore
        c[_tabPathCogs[TrailTab.explore]] = [.region(trail.regionID), .trail(trailID)]
        c[_presentedSheetCog] = .hikeLogger(trailID)
      }
    case .search(let query):
      turn { c in
        c[_selectedTabCog] = .search
        c[_tabPathCogs[TrailTab.search]] = []
        c[_presentedSheetCog] = nil
        self.setSearchQuery(query)
      }
    }
  }

  /// Parses and applies a URL from any system entry point.
  ///
  /// Unrecognized URLs are ignored: an app must never crash or navigate
  /// somewhere broken because another process composed a bad link.
  ///
  /// - Parameter url: The incoming URL.
  func open(url: URL) {
    guard let link = TrailDeepLink(url: url) else { return }
    open(link)
  }

  /// Appends one visit to the session journal, newest first, capped at 50.
  ///
  /// Called by the journal mechanism's reaction, which runs after the turn
  /// that changed the screen has settled; this write therefore queues as its
  /// own later turn rather than joining the one it observed.
  ///
  /// - Parameter screen: The screen that just became topmost.
  func recordScreenVisit(_ screen: TrailScreen) {
    turn { c in
      let journal = c[_screenJournalCog]
      let visit = TrailScreenVisit(id: (journal.first?.id ?? 0) + 1, screen: screen)
      c[_screenJournalCog] = Array(([visit] + journal).prefix(50))
    }
  }

  /// Empties the session journal.
  func clearScreenJournal() {
    turn(_screenJournalCog, to: [])
  }

  /// Installs restored navigation state during assembly.
  ///
  /// The domain install operation calls this inside its own turn body, so
  /// navigation and domain state land as one turn even though their sources
  /// live in different files.
  ///
  /// - Parameters:
  ///   - tab: The tab to select.
  ///   - paths: Every tab's stack; missing tabs restore to their roots.
  ///   - sheet: The sheet to re-present, if one was up.
  func installNavigation(tab: TrailTab, paths: [TrailTab: [TrailRoute]], sheet: TrailSheet?) {
    turn { c in
      c[_selectedTabCog] = tab
      for tab in TrailTab.allCases {
        c[_tabPathCogs[tab]] = paths[tab] ?? []
      }
      c[_presentedSheetCog] = sheet
    }
  }
}
