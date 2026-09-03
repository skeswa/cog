import Cog
import Foundation

// The Trail rig's declarations and ops: saved trails, search, and hike
// logging. Navigation state lives in the Navigation rig's
// `NavigationRig+Cogs.swift`. Per-file source privacy still supports cross-rig
// operations: a turn may call the other rig's operation, and the nested turn
// joins.

/// Bookmarked trails in the order they were saved.
private let _savedTrailIDsCog = Cog<[TrailID]>.Manual { [] }
/// Raw text in the Search tab's field.
private let _searchQueryCog = Cog<String>.Manual { "" }
/// Logged hikes, most recent first.
private let _hikeEntriesCog = Cog<[HikeEntry]>.Manual { [] }
/// Whole seconds the hike logger has been open, driven by the gated timer.
private let _hikeTimerSecondsCog = Cog<Int>.Manual { 0 }

/// Read-only saved-trail membership.
let savedTrailIDsCog = _savedTrailIDsCog.readOnly
/// Read-only search text.
let searchQueryCog = _searchQueryCog.readOnly
/// Read-only hike log.
let hikeEntriesCog = _hikeEntriesCog.readOnly
/// Read-only logger elapsed seconds.
let hikeTimerSecondsCog = _hikeTimerSecondsCog.readOnly

/// Whether one trail is bookmarked, keyed so each detail screen and row
/// notices only its own trail's membership changes.
let isTrailSavedCogs = CogBox<Bool, TrailID> { c, trailID in
  let savedTrailIDs = c[savedTrailIDsCog]
  return savedTrailIDs.contains(trailID)
}

/// Number of bookmarks, equality-gated for the Saved tab badge.
///
/// The tab bar reads this instead of the membership array, so reordering or
/// replacing bookmarks without changing their count re-renders no tab chrome.
let savedTrailCountCog = Cog<Int> { c in
  let savedTrailIDs = c[savedTrailIDsCog]
  return savedTrailIDs.count
}

/// Trails matching the search text, recomputed only when the text changes.
///
/// The catalog is immutable fixture data, so the query is this value's only
/// dependency; results are identities, and rows look the content up.
let searchResultsCog = Cog<[TrailID]> { c in
  let searchQuery = c[searchQueryCog]
  return TrailCatalog.trailIDs(matching: searchQuery)
}

/// Number of logged hikes for one trail, keyed per detail screen.
let hikeCountCogs = CogBox<Int, TrailID> { c, trailID in
  let hikeEntries = c[hikeEntriesCog]
  return hikeEntries.filter { $0.trailID == trailID }.count
}

/// Whole-value document observed only by the persistence mechanism.
///
/// It aggregates navigation and domain facts from one settled turn, so storage
/// never sees a new tab with an old stack.
/// The search query and journal are session-scoped and deliberately absent.
let trailSnapshotCog = Cog<TrailSnapshot> { c in
  let selectedTab = c[selectedTabCog]
  let paths = TrailTab.allCases.reduce(into: [TrailTab: [TrailRoute]]()) { paths, tab in
    paths[tab] = c[tabPathCogs[tab]]
  }
  let presentedSheet = c[presentedSheetCog]
  let savedTrailIDs = c[savedTrailIDsCog]
  let hikeEntries = c[hikeEntriesCog]
  return TrailSnapshot(
    tab: selectedTab,
    paths: paths,
    sheet: presentedSheet,
    savedTrailIDs: savedTrailIDs,
    hikeEntries: hikeEntries
  )
}

extension CogOps {
  /// Bookmarks a trail, or removes an existing bookmark.
  ///
  /// - Parameter trailID: The trail whose membership flips.
  func toggleSavedTrail(_ trailID: TrailID) {
    turn { c in
      let savedTrailIDs = c[_savedTrailIDsCog]
      if savedTrailIDs.contains(trailID) {
        c[_savedTrailIDsCog] = savedTrailIDs.filter { $0 != trailID }
      } else {
        c[_savedTrailIDsCog] = savedTrailIDs + [trailID]
      }
    }
  }

  /// Replaces the search text with the field's latest value.
  ///
  /// - Parameter query: Uncommitted text, including surrounding whitespace.
  func setSearchQuery(_ query: String) {
    turn(_searchQueryCog, to: query)
  }

  /// Commits a hike entry and dismisses the logger in one settled turn.
  ///
  /// `dismissSheet` opens a nested turn that joins this one. The new entry,
  /// reset timer, and dismissal publish together, so no observer sees a logged
  /// hike behind an open logger.
  ///
  /// - Parameters:
  ///   - trailID: The trail the hike was on.
  ///   - note: Raw note text; surrounding whitespace is trimmed.
  ///   - id: Entry identity; tests may pass a deterministic one.
  ///   - date: Commit moment; tests may pass a fixed one.
  func logHike(
    for trailID: TrailID,
    note: String,
    id: HikeEntryID = HikeEntryID(),
    at date: Date = Date.now
  ) {
    turn { c in
      let entry = HikeEntry(
        id: id,
        trailID: trailID,
        note: note.trimmingCharacters(in: .whitespacesAndNewlines),
        loggedSeconds: c[_hikeTimerSecondsCog],
        loggedAt: date
      )
      c[_hikeEntriesCog] = [entry] + c[_hikeEntriesCog]
      self.dismissSheet()
    }
  }

  /// Restarts the logger clock; the timer scope calls this as it opens.
  func resetHikeTimer() {
    turn(_hikeTimerSecondsCog, to: 0)
  }

  /// Advances the logger clock by one second.
  func tickHikeTimer() {
    turn { c in
      c[_hikeTimerSecondsCog] += 1
    }
  }

  /// Installs a complete restored document during mechanism assembly.
  ///
  /// Runs inside `operate`, so every write settles before `assemble`
  /// returns and the first rendered frame is already the restored screen.
  /// `installNavigation` joins this turn from the navigation state file.
  ///
  /// - Parameter snapshot: The restored document.
  func installTrailState(_ snapshot: TrailSnapshot) {
    turn { c in
      c[_savedTrailIDsCog] = snapshot.savedTrailIDs
      c[_hikeEntriesCog] = snapshot.hikeEntries
      c[_searchQueryCog] = ""
      self.installNavigation(tab: snapshot.tab, paths: snapshot.paths, sheet: snapshot.sheet)
    }
  }
}
