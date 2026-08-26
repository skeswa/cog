import Foundation

// The value types the domain state's cogs, operations, and mechanisms manage:
// the identities that key boxes and travel through routes and deep links, the
// logged-hike record, and the durable snapshot document. Catalog content —
// what a region or trail *is* — lives in `TrailCatalog.swift`, because content
// is fixture data rather than state.

/// Stable identity for one region across Cog keys, routes, and deep links.
nonisolated struct RegionID: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
  /// The persisted slug backing this identity; it appears verbatim in URLs.
  let rawValue: String

  /// SwiftUI list identity equal to the Cog box key.
  var id: Self { self }

  /// Wraps a catalog or deep-link slug without validating it.
  ///
  /// Unknown slugs stay representable so a stale deep link can fail softly at
  /// resolution instead of crashing at parse time.
  ///
  /// - Parameter rawValue: The slug to preserve across URL round trips.
  init(rawValue: String) {
    self.rawValue = rawValue
  }
}

extension RegionID: CustomStringConvertible {
  /// Compact text used in keyed debug-history names.
  var description: String { rawValue }
}

/// Stable identity for one trail across Cog keys, routes, and deep links.
nonisolated struct TrailID: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
  /// The persisted slug backing this identity; it appears verbatim in URLs.
  let rawValue: String

  /// SwiftUI list identity equal to the Cog box key.
  var id: Self { self }

  /// Wraps a catalog or deep-link slug without validating it.
  ///
  /// - Parameter rawValue: The slug to preserve across URL round trips.
  init(rawValue: String) {
    self.rawValue = rawValue
  }
}

extension TrailID: CustomStringConvertible {
  /// Compact text used in keyed debug-history names.
  var description: String { rawValue }
}

/// Stable identity for one logged hike across persistence round trips.
nonisolated struct HikeEntryID: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
  /// The persisted UUID backing this identity.
  let rawValue: UUID

  /// SwiftUI list identity for journal rows.
  var id: Self { self }

  /// Creates a fresh identity unless a deterministic UUID is supplied by a test.
  ///
  /// - Parameter rawValue: The UUID to preserve across persistence round trips.
  init(rawValue: UUID = UUID()) {
    self.rawValue = rawValue
  }
}

/// One hike recorded through the logger sheet.
nonisolated struct HikeEntry: Codable, Equatable, Identifiable, Sendable {
  /// Stable row identity.
  let id: HikeEntryID
  /// The trail this hike was logged against.
  let trailID: TrailID
  /// Normalized user note; may be empty.
  let note: String
  /// Whole seconds the logger sheet stayed open, from the gated timer.
  let loggedSeconds: Int
  /// Wall-clock moment the entry was committed.
  let loggedAt: Date
}

/// The durable navigation-and-domain document written by the persistence
/// mechanism.
///
/// The search query and journal are deliberately absent: both are
/// session-scoped by design, so a relaunch restores where the user was, not
/// what they were mid-typing.
nonisolated struct TrailSnapshot: Codable, Equatable, Sendable {
  /// The selected tab.
  let tab: TrailTab
  /// Every tab's navigation stack, including tabs not currently selected.
  let paths: [TrailTab: [TrailRoute]]
  /// The presented sheet, restored so a relaunch mid-log resumes the logger.
  let sheet: TrailSheet?
  /// Bookmarked trails in the order they were saved.
  let savedTrailIDs: [TrailID]
  /// Logged hikes, most recent first.
  let hikeEntries: [HikeEntry]
}
