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
/// Because `operate` runs inside assembly, the restored tab, stacks, and sheet
/// settle before `assemble` returns. SwiftUI's first frame shows the restored
/// screen without flashing the resting defaults.
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

/// Ticks the hike logger's elapsed clock only while its sheet is presented.
///
/// The `whenever` scope's gate is the derived `isLoggingHikeCog`, so the
/// navigation state controls the ticking task. Presenting the logger starts a
/// fresh scope. A button, swipe, or deep link dismissal cancels it in the same
/// flush. Each presentation restarts from zero.
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
