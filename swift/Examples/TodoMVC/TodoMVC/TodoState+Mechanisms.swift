import Cog
import Foundation

/// MainActor persistence boundary for the TodoMVC document.
///
/// Storage never becomes a second live state source. The mechanism reads it
/// once during assembly, then the Cog graph is authoritative for the running
/// app and writes completed snapshots back through this capability.
struct TodoStore {
  /// Stable key for the example's JSON document.
  private static let storageKey = "com.skeswa.cog.todomvc.snapshot"

  /// Loads the last durable document, or `nil` on first launch.
  private let loadBody: @MainActor () -> TodoSnapshot?
  /// Persists one coherent graph snapshot.
  private let saveBody: @MainActor (TodoSnapshot) -> Void

  /// UserDefaults-backed production storage.
  static let live = Self(
    load: {
      guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
      return try? JSONDecoder().decode(TodoSnapshot.self, from: data)
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
    load: @escaping @MainActor () -> TodoSnapshot?,
    save: @escaping @MainActor (TodoSnapshot) -> Void
  ) {
    loadBody = load
    saveBody = save
  }

  /// Reads the starting document on the graph's actor.
  func load() -> TodoSnapshot? {
    loadBody()
  }

  /// Writes one accepted document on the graph's actor.
  ///
  /// - Parameter snapshot: Coherent todos and filter from one completed turn.
  func save(_ snapshot: TodoSnapshot) {
    saveBody(snapshot)
  }
}

/// TodoMVC's mechanism installs starting state and owns persistence.
struct TodoMechanism: Mechanism {
  /// Storage capability retained for the mechanism scope's lifetime.
  let store: TodoStore
  /// Rows shown when no durable document exists.
  var firstRunTodos = TodoItem.examples

  /// Installs initial state before observation, then persists later changes.
  ///
  /// Composer text is intentionally absent from ``todoSnapshotCog``. Typing
  /// therefore changes only UI state; a durable write occurs after a todo,
  /// title, completion, membership, or filter change.
  ///
  /// - Parameter m: Assembly-only controller owned by the runtime scope.
  func operate(_ m: MechanismController) {
    let snapshot =
      store.load()
      ?? TodoSnapshot(todos: firstRunTodos, filter: .all)
    m.installTodos(snapshot.todos, filter: snapshot.filter)

    m.watch(todoSnapshotCog, initial: .skip, name: "persistence") { _, snapshot in
      store.save(snapshot)
    }
  }
}
