import Foundation

/// Every URL the app understands, as a parsed value.
///
/// Parsing and printing are pure and inverse of each other, so links can be
/// unit-tested without a graph and journal rows can show the exact URL that
/// reproduces a screen. Resolution to navigation state happens separately, in
/// the `open` operation, where unknown identities fail softly.
///
/// The grammar, using ``TrailTab`` raw values as hosts:
///
/// ```text
/// cog-trails://explore | search | saved | journal
/// cog-trails://search?q=<query>
/// cog-trails://region/<region-id>
/// cog-trails://trail/<trail-id>
/// cog-trails://trail/<trail-id>/log
/// ```
nonisolated enum TrailDeepLink: Equatable, Hashable, Sendable {
  /// Selects a tab at its root.
  case tab(TrailTab)
  /// Opens one region's trail list on the Explore tab.
  case region(RegionID)
  /// Opens one trail's detail, stacked on its region, on the Explore tab.
  case trail(TrailID)
  /// Opens one trail's detail and presents the hike logger over it.
  case hikeLogger(TrailID)
  /// Opens the Search tab with a query already applied.
  case search(String)

  /// The custom scheme registered in the app's `Info.plist`.
  static let scheme = "cog-trails"

  /// Parses a URL, or returns `nil` for one this app does not understand.
  ///
  /// Parsing validates shape only, never existence: an unknown trail slug
  /// still parses, and the `open` operation drops it against the catalog.
  ///
  /// - Parameter url: A candidate URL from any entry point.
  init?(url: URL) {
    guard
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.scheme == Self.scheme,
      let host = components.host
    else { return nil }

    let segments = url.pathComponents.filter { $0 != "/" }

    if host == "search" {
      let query = components.queryItems?.first { $0.name == "q" }?.value ?? ""
      self = query.isEmpty ? .tab(.search) : .search(query)
      return
    }
    if let tab = TrailTab(rawValue: host) {
      self = .tab(tab)
      return
    }

    switch host {
    case "region":
      guard let slug = segments.first else { return nil }
      self = .region(RegionID(rawValue: slug))
    case "trail":
      guard let slug = segments.first else { return nil }
      let trailID = TrailID(rawValue: slug)
      self = segments.count > 1 && segments[1] == "log" ? .hikeLogger(trailID) : .trail(trailID)
    default:
      return nil
    }
  }

  /// The canonical URL for this link; `init(url:)` parses it back exactly.
  var url: URL {
    var components = URLComponents()
    components.scheme = Self.scheme
    switch self {
    case .tab(let tab):
      components.host = tab.rawValue
    case .region(let regionID):
      components.host = "region"
      components.path = "/\(regionID.rawValue)"
    case .trail(let trailID):
      components.host = "trail"
      components.path = "/\(trailID.rawValue)"
    case .hikeLogger(let trailID):
      components.host = "trail"
      components.path = "/\(trailID.rawValue)/log"
    case .search(let query):
      components.host = "search"
      components.queryItems = [URLQueryItem(name: "q", value: query)]
    }
    guard let url = components.url else {
      fatalError("TrailDeepLink produced invalid URL components for \(self)")
    }
    return url
  }
}
