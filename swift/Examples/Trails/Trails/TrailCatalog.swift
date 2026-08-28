import Foundation

// The immutable content model for regions and trails. The graph manages
// identities and user facts with the `TrailState+Model.swift` types. Screens
// resolve those identities through this catalog.

/// Effort rating shown on trail rows and detail screens.
nonisolated enum TrailDifficulty: String, CaseIterable, Codable, Sendable {
  /// Flat, short, and family-friendly.
  case easy
  /// Sustained climbing or distance.
  case moderate
  /// Long days, exposure, or scrambling.
  case strenuous

  /// Human-readable rating label.
  var label: String {
    switch self {
    case .easy: "Easy"
    case .moderate: "Moderate"
    case .strenuous: "Strenuous"
    }
  }

  /// SF Symbol paired with the rating everywhere it appears.
  var symbol: String {
    switch self {
    case .easy: "figure.walk"
    case .moderate: "figure.hiking"
    case .strenuous: "figure.climbing"
    }
  }
}

/// One browseable area of the trail catalog.
nonisolated struct Region: Codable, Equatable, Identifiable, Sendable {
  /// Stable route, key, and deep-link identity.
  let id: RegionID
  /// Display name used in lists and navigation titles.
  let name: String
  /// One-line flavor text under the name.
  let tagline: String
  /// SF Symbol shown beside the region.
  let symbol: String
}

/// One hikeable trail inside a region.
nonisolated struct Trail: Codable, Equatable, Identifiable, Sendable {
  /// Stable route, key, and deep-link identity.
  let id: TrailID
  /// The region this trail belongs to; deep links resolve it to a full path.
  let regionID: RegionID
  /// Display name used in lists and navigation titles.
  let name: String
  /// Round-trip length in miles.
  let miles: Double
  /// Effort rating for the whole route.
  let difficulty: TrailDifficulty
  /// Short description shown on the detail screen.
  let blurb: String
}

/// The immutable content catalog behind every screen.
///
/// The catalog is fixture data, not app state: nothing mutates it, so it never
/// belongs in the Cog graph. Routes and deep links carry only `RegionID` and
/// `TrailID` values, and screens look the content up here. That split is what
/// makes a cold-start deep link identical to warm in-app navigation.
nonisolated enum TrailCatalog {
  /// Every region in display order.
  static let regions: [Region] = [
    Region(
      id: RegionID(rawValue: "cascade-hollow"),
      name: "Cascade Hollow",
      tagline: "Mossy gorges and year-round waterfalls.",
      symbol: "mountain.2.fill"
    ),
    Region(
      id: RegionID(rawValue: "sunridge-desert"),
      name: "Sunridge Desert",
      tagline: "Slot canyons and saguaro-lined washes.",
      symbol: "sun.max.fill"
    ),
    Region(
      id: RegionID(rawValue: "silver-coast"),
      name: "Silver Coast",
      tagline: "Sea stacks, tidepools, and bluff-top light.",
      symbol: "water.waves"
    ),
  ]

  /// Every trail in display order, grouped by region.
  static let trails: [Trail] = [
    Trail(
      id: TrailID(rawValue: "hollow-falls-loop"),
      regionID: RegionID(rawValue: "cascade-hollow"),
      name: "Hollow Falls Loop",
      miles: 3.4,
      difficulty: .easy,
      blurb: "A boardwalk loop beneath the lower falls, misty in every season."
    ),
    Trail(
      id: TrailID(rawValue: "mist-ridge"),
      regionID: RegionID(rawValue: "cascade-hollow"),
      name: "Mist Ridge",
      miles: 7.1,
      difficulty: .moderate,
      blurb: "Switchbacks to a ridgeline view over three cascades at once."
    ),
    Trail(
      id: TrailID(rawValue: "old-fir-traverse"),
      regionID: RegionID(rawValue: "cascade-hollow"),
      name: "Old Fir Traverse",
      miles: 11.8,
      difficulty: .strenuous,
      blurb: "A full-day traverse through old growth, ending at the upper basin."
    ),
    Trail(
      id: TrailID(rawValue: "painted-wash"),
      regionID: RegionID(rawValue: "sunridge-desert"),
      name: "Painted Wash",
      miles: 4.2,
      difficulty: .easy,
      blurb: "A sandy wash walk past banded rock that glows at golden hour."
    ),
    Trail(
      id: TrailID(rawValue: "saguaro-crown"),
      regionID: RegionID(rawValue: "sunridge-desert"),
      name: "Saguaro Crown",
      miles: 6.5,
      difficulty: .moderate,
      blurb: "A climb through the densest saguaro stand on the ridge crown."
    ),
    Trail(
      id: TrailID(rawValue: "rimrock-scramble"),
      regionID: RegionID(rawValue: "sunridge-desert"),
      name: "Rimrock Scramble",
      miles: 9.9,
      difficulty: .strenuous,
      blurb: "Class-2 scrambling along the rim with long, airy exposure."
    ),
    Trail(
      id: TrailID(rawValue: "tidepool-walk"),
      regionID: RegionID(rawValue: "silver-coast"),
      name: "Tidepool Walk",
      miles: 2.1,
      difficulty: .easy,
      blurb: "A low-tide amble across anemone gardens and sculpted shale."
    ),
    Trail(
      id: TrailID(rawValue: "lighthouse-bluffs"),
      regionID: RegionID(rawValue: "silver-coast"),
      name: "Lighthouse Bluffs",
      miles: 5.6,
      difficulty: .moderate,
      blurb: "Bluff-top meadows from the harbor to the working lighthouse."
    ),
    Trail(
      id: TrailID(rawValue: "sea-stack-point"),
      regionID: RegionID(rawValue: "silver-coast"),
      name: "Sea Stack Point",
      miles: 8.4,
      difficulty: .strenuous,
      blurb: "An out-and-back to the point, dropping to two hidden coves."
    ),
  ]

  /// Looks up one region, or `nil` for a stale or mistyped identity.
  ///
  /// - Parameter id: Region identity from a route or deep link.
  static func region(_ id: RegionID) -> Region? {
    regions.first { $0.id == id }
  }

  /// Looks up one trail, or `nil` for a stale or mistyped identity.
  ///
  /// - Parameter id: Trail identity from a route or deep link.
  static func trail(_ id: TrailID) -> Trail? {
    trails.first { $0.id == id }
  }

  /// Every trail in one region, in catalog order.
  ///
  /// - Parameter regionID: The containing region.
  static func trails(in regionID: RegionID) -> [Trail] {
    trails.filter { $0.regionID == regionID }
  }

  /// Case-insensitive name and region match used by the Search tab.
  ///
  /// A blank query matches nothing so the Search screen can show its prompt
  /// state rather than the whole catalog.
  ///
  /// - Parameter query: Raw text from the search field.
  static func trailIDs(matching query: String) -> [TrailID] {
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else { return [] }

    return
      trails
      .filter { trail in
        let regionName = region(trail.regionID)?.name ?? ""
        return trail.name.lowercased().contains(normalized)
          || regionName.lowercased().contains(normalized)
      }
      .map(\.id)
  }
}
