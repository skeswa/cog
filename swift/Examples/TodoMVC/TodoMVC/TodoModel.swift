import Foundation

/// Stable identity for one todo across Cog keys, list updates, and persistence.
nonisolated struct TodoID: RawRepresentable, Codable, Hashable, Identifiable, Sendable {
  /// The persisted UUID backing this identity.
  let rawValue: UUID

  /// SwiftUI list identity equal to the Cog box key.
  var id: Self { self }

  /// Creates a fresh identity unless a deterministic UUID is supplied by a test.
  ///
  /// - Parameter rawValue: The UUID to preserve across persistence round trips.
  init(rawValue: UUID = UUID()) {
    self.rawValue = rawValue
  }
}

extension TodoID: CustomStringConvertible {
  /// Compact text used in keyed debug-history names.
  var description: String { rawValue.uuidString }
}

/// The classic TodoMVC visibility filters.
nonisolated enum TodoFilter: String, CaseIterable, Codable, Identifiable, Sendable {
  /// Shows every todo in insertion order.
  case all
  /// Shows only incomplete todos.
  case active
  /// Shows only completed todos.
  case completed

  /// Picker identity equal to the serialized filter value.
  var id: Self { self }

  /// Human-readable picker label.
  var label: String {
    switch self {
    case .all: "All"
    case .active: "Active"
    case .completed: "Completed"
    }
  }

  /// Empty-state title for the selected subset.
  var emptyTitle: String {
    switch self {
    case .all: "Nothing to do"
    case .active: "All caught up"
    case .completed: "No completed todos"
    }
  }

  /// Empty-state explanation for the selected subset.
  var emptyMessage: String {
    switch self {
    case .all: "Add a todo above to start your list."
    case .active: "Every todo on your list is complete."
    case .completed: "Completed todos will collect here."
    }
  }

  /// SF Symbol used by the selected subset's empty state.
  var emptySymbol: String {
    switch self {
    case .all: "checklist"
    case .active: "checkmark.seal.fill"
    case .completed: "archivebox"
    }
  }
}

/// A transport value used only at persistence and test boundaries.
///
/// Live graph state keeps title and completion in separate keyed sources so a
/// change to one row does not invalidate its siblings. This whole-value type is
/// reconstructed only when the persistence mechanism asks for a snapshot.
nonisolated struct TodoItem: Codable, Equatable, Identifiable, Sendable {
  /// Stable row and Cog-box identity.
  let id: TodoID
  /// User-authored task text.
  let title: String
  /// Whether the task is complete.
  let isCompleted: Bool

  /// The populated first-run list that makes the example self-explanatory.
  static let examples = [
    Self(
      id: TodoID(rawValue: UUID(uuidString: "4D412F2E-C1D2-4FE4-9EB7-50D5BF905CB5")!),
      title: "Build something delightful with Cog",
      isCompleted: false
    ),
    Self(
      id: TodoID(rawValue: UUID(uuidString: "1BC2A5ED-3C66-4F51-AF7E-1712BD8E01A7")!),
      title: "Toggle a task to watch derived state settle",
      isCompleted: false
    ),
    Self(
      id: TodoID(rawValue: UUID(uuidString: "A0AC9E19-F36E-476D-97DB-9DF77B5AE5AA")!),
      title: "Try the Active and Completed filters",
      isCompleted: true
    ),
  ]
}

/// The durable TodoMVC document written by ``TodoMechanism``.
nonisolated struct TodoSnapshot: Codable, Equatable, Sendable {
  /// Todos in their visible insertion order.
  let todos: [TodoItem]
  /// The last selected visibility filter.
  let filter: TodoFilter
}

extension String {
  /// TodoMVC's committed-title normalization.
  var normalizedTodoTitle: String {
    trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
