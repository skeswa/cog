import Cog
import Foundation

/// MainActor persistence boundary for the Trails document.
///
/// Storage never becomes a second live state source. The persistence
/// mechanism reads it once during assembly, then the Cog graph is
/// authoritative for the running app and writes completed snapshots back
/// through this capability.
struct TrailStore {
  /// Stable key for the example's JSON document.
  private static let storageKey = "com.skeswa.cog.trails.snapshot"

  /// Loads the last durable document, or `nil` on first launch.
  private let loadBody: @MainActor () -> TrailSnapshot?
  /// Persists one coherent graph snapshot.
  private let saveBody: @MainActor (TrailSnapshot) -> Void

  /// UserDefaults-backed production storage.
  static let live = Self(
    load: {
      guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
      return try? JSONDecoder().decode(TrailSnapshot.self, from: data)
    },
    save: { snapshot in
      guard let data = try? JSONEncoder().encode(snapshot) else { return }
      UserDefaults.standard.set(data, forKey: storageKey)
    }
  )

  /// Creates an injectable synchronous store.
  ///
  /// - Parameters:
  ///   - load: Reads the optional starting document during assembly.
  ///   - save: Receives each later accepted graph snapshot.
  init(
    load: @escaping @MainActor () -> TrailSnapshot?,
    save: @escaping @MainActor (TrailSnapshot) -> Void
  ) {
    loadBody = load
    saveBody = save
  }

  /// Reads the starting document on the graph's actor.
  func load() -> TrailSnapshot? {
    loadBody()
  }

  /// Writes one accepted document on the graph's actor.
  ///
  /// - Parameter snapshot: Coherent navigation and domain state from one
  ///   completed turn.
  func save(_ snapshot: TrailSnapshot) {
    saveBody(snapshot)
  }
}

/// Restores the last session during assembly, then persists later changes.
///
/// Because `operate` runs inside assembly, the restored tab, stacks, and
/// sheet settle before `assemble` returns — the first frame SwiftUI renders
/// is already the restored screen, with no flash of the resting defaults.
/// Cold-launch deep links then land on top of this as ordinary later turns.
struct TrailPersistenceMechanism: Mechanism {
  /// Storage capability retained for the mechanism scope's lifetime.
  let store: TrailStore

  /// The clean-install document: Explore at its root, nothing saved.
  private static let firstRun = TrailSnapshot(
    tab: .explore,
    paths: [:],
    sheet: nil,
    savedTrailIDs: [],
    hikeEntries: []
  )

  /// Installs the starting document, then watches the snapshot for writes.
  ///
  /// - Parameter m: Assembly-only controller owned by the runtime scope.
  func operate(_ m: MechanismController) {
    m.installTrailState(store.load() ?? Self.firstRun)

    m.watch(trailSnapshotCog, initial: .skip, name: "persistence") { _, snapshot in
      store.save(snapshot)
    }
  }
}

/// Records every screen transition into the session journal.
///
/// This is the analytics pattern with the analytics service replaced by a
/// visible in-app log: one reaction on the derived `currentScreenCog`
/// observes every navigation, however it happened — tap, gesture, deep link,
/// or restoration — with no per-screen instrumentation. The reaction's write
/// queues as its own later turn, after the navigation turn it observed.
struct TrailJournalMechanism: Mechanism {
  /// Watches the derived screen and appends each settled transition.
  ///
  /// `initial: .run` records the restored screen as the session's first
  /// entry, because the persistence mechanism is listed first at assembly.
  ///
  /// - Parameter m: Assembly-only controller owned by the runtime scope.
  func operate(_ m: MechanismController) {
    m.watch(currentScreenCog, initial: .run, name: "journal") { [weak m] _, screen in
      m?.recordScreenVisit(screen)
    }
  }
}

/// Ticks the hike logger's elapsed clock while — and only while — the logger
/// sheet is presented.
///
/// The `whenever` scope's gate is the derived `isLoggingHikeCog`, so the
/// ticking task's lifetime is decided by navigation state itself: presenting
/// the logger starts a fresh scope, and dismissal — by button, swipe, or a
/// deep link that navigates away — cancels it in the same flush. Nothing
/// survives a down-and-up cycle, so each presentation restarts from zero.
struct HikeTimerMechanism: Mechanism {
  /// Injected clock; tests substitute a controlled one.
  var clock: any Clock<Duration> = ContinuousClock()

  /// Registers the navigation-gated timer scope.
  ///
  /// - Parameter m: Assembly-only controller owned by the runtime scope.
  func operate(_ m: MechanismController) {
    m.whenever(isLoggingHikeCog, name: "hikeTimer") { s in
      s.resetHikeTimer()
      s.task(name: "tick") { [weak s] in
        while true {
          try await clock.sleep(for: .seconds(1))
          guard let s else { return }
          await s.tickHikeTimer()
        }
      }
    }
  }
}
