// The value types the navigation state's cogs, operations, and mechanisms
// manage: the tab, route, sheet, and derived-screen vocabulary, plus the
// journal's visit record. Routes carry identities from
// `TrailRig+Model.swift` and never loaded content.

/// The four top-level destinations in the tab bar.
///
/// Raw values double as deep-link hosts (`cog-trails://saved`), so renaming a
/// case is a link-format change, not just a refactor.
nonisolated enum TrailTab: String, CaseIterable, Codable, Identifiable, Sendable {
  /// Region-first catalog browsing.
  case explore
  /// Free-text trail search.
  case search
  /// Trails the user bookmarked.
  case saved
  /// The session's screen-visit journal.
  case journal

  /// ForEach and tab-selection identity equal to the serialized value.
  var id: Self { self }

  /// Human-readable tab label.
  var label: String {
    switch self {
    case .explore: "Explore"
    case .search: "Search"
    case .saved: "Saved"
    case .journal: "Journal"
    }
  }

  /// SF Symbol shown on the tab item.
  var symbol: String {
    switch self {
    case .explore: "map.fill"
    case .search: "magnifyingglass"
    case .saved: "bookmark.fill"
    case .journal: "clock.arrow.circlepath"
    }
  }
}

/// One pushable step in a tab's navigation stack.
///
/// Routes carry identities, never loaded models. Screens resolve the content
/// from ``TrailCatalog``, which keeps every route value small, `Codable` for
/// restoration, and constructible from a parsed URL.
nonisolated enum TrailRoute: Codable, Hashable, Sendable {
  /// The trail list for one region.
  case region(RegionID)
  /// The detail screen for one trail.
  case trail(TrailID)
}

/// One modal layer presented over the whole tab interface.
///
/// The sheet is deliberately a separate fact from the stacks: presenting or
/// dismissing it must not invalidate any path reader. New cases extend this
/// enum rather than adding boolean presentation flags.
nonisolated enum TrailSheet: Codable, Hashable, Identifiable, Sendable {
  /// The hike logger for one trail.
  case hikeLogger(TrailID)

  /// `sheet(item:)` identity equal to the value itself.
  var id: Self { self }
}

/// The single topmost thing on screen, derived from tab, path, and sheet.
///
/// This value exists only as the output of `currentScreenCog`; nothing stores
/// it. The journal mechanism watches it for analytics-style screen tracking.
nonisolated enum TrailScreen: Equatable, Hashable, Sendable {
  /// A tab is showing its root list.
  case tabRoot(TrailTab)
  /// A region's trail list is on top.
  case region(RegionID)
  /// A trail detail screen is on top.
  case trail(TrailID)
  /// The hike logger sheet covers everything else.
  case hikeLogger(TrailID)

  /// The canonical deep link that reproduces this screen.
  ///
  /// Journal rows navigate by round-tripping through this value, proving that
  /// every reachable screen has a working URL.
  var deepLink: TrailDeepLink {
    switch self {
    case .tabRoot(let tab): .tab(tab)
    case .region(let regionID): .region(regionID)
    case .trail(let trailID): .trail(trailID)
    case .hikeLogger(let trailID): .hikeLogger(trailID)
    }
  }

  /// Display name for journal rows, resolved through the catalog.
  var journalLabel: String {
    switch self {
    case .tabRoot(let tab):
      tab.label
    case .region(let regionID):
      TrailCatalog.region(regionID)?.name ?? regionID.rawValue
    case .trail(let trailID):
      TrailCatalog.trail(trailID)?.name ?? trailID.rawValue
    case .hikeLogger(let trailID):
      "Logging \(TrailCatalog.trail(trailID)?.name ?? trailID.rawValue)"
    }
  }

  /// SF Symbol for journal rows.
  var journalSymbol: String {
    switch self {
    case .tabRoot(let tab): tab.symbol
    case .region: "mountain.2"
    case .trail: "signpost.right"
    case .hikeLogger: "pencil.line"
    }
  }
}

/// One recorded visit in the session journal.
nonisolated struct TrailScreenVisit: Equatable, Identifiable, Sendable {
  /// Monotonically increasing identity; newer visits have larger values.
  let id: Int
  /// The screen that became topmost.
  let screen: TrailScreen
}
