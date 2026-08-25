#if DEBUG

import Cog
import CogTesting
import Foundation

extension Cogs {
  /// Seeds a coherent TodoMVC document before a test begins observing it.
  ///
  /// - Parameters:
  ///   - todos: Ordered keyed rows to install without a turn.
  ///   - filter: Visibility selection to install without a turn.
  func seedTodos(_ todos: [TodoItem], filter: TodoFilter = .all) {
    seed(todoIDsSeedTargetCog, to: todos.map(\.id))
    seed(todoFilterSeedTargetCog, to: filter)
    seed(newTodoTitleSeedTargetCog, to: "")
    for todo in todos {
      seed(todoTitleSeedTargetCogs[todo.id], to: todo.title)
      seed(todoIsCompletedSeedTargetCogs[todo.id], to: todo.isCompleted)
    }
  }
}

/// Deterministic identity helper for concise test arrangements.
///
/// - Parameter suffix: Final hexadecimal digit placed in an otherwise-zero UUID.
/// - Returns: Stable identity unique within one test.
nonisolated func todoID(_ suffix: Int) -> TodoID {
  let text = String(format: "00000000-0000-0000-0000-%012X", suffix)
  return TodoID(rawValue: UUID(uuidString: text)!)
}

#endif
