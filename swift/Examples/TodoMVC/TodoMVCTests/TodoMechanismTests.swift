#if DEBUG

import Cog
import CogTesting
import Testing

/// Mutable persistence probe captured by an injected ``TodoStore``.
@MainActor
private final class TodoStoreRecorder {
  /// Document returned during assembly.
  var loaded: TodoSnapshot?
  /// Documents written by the persistence reaction.
  private(set) var saved: [TodoSnapshot] = []

  /// Store capability whose calls remain on this actor.
  var store: TodoStore {
    TodoStore(
      load: { [weak self] in self?.loaded },
      save: { [weak self] snapshot in self?.saved.append(snapshot) }
    )
  }

  /// Explicitly avoids an unnecessary MainActor deallocation hop.
  nonisolated deinit {}
}

@MainActor
@Test func mechanismRestoresPersistenceBeforeAnythingObservesTheGraph() {
  let restored = TodoItem(id: todoID(1), title: "Restored", isCompleted: true)
  let recorder = TodoStoreRecorder()
  recorder.loaded = TodoSnapshot(todos: [restored], filter: .completed)

  let cogs = Cogs.forTesting(mechanisms: [
    TodoMechanism(store: recorder.store, firstRunTodos: [])
  ])

  let todoIDs = cogs.peek(todoIDsCog)
  let todoFilter = cogs.peek(todoFilterCog)
  let todoTitle = cogs.peek(todoTitleCogs[restored.id])
  let todoIsCompleted = cogs.peek(todoIsCompletedCogs[restored.id])
  #expect(todoIDs == [restored.id])
  #expect(todoFilter == .completed)
  #expect(todoTitle == "Restored")
  #expect(todoIsCompleted)
  #expect(recorder.saved.isEmpty)
}

@MainActor
@Test func mechanismUsesTheDemoDocumentOnFirstLaunch() {
  let recorder = TodoStoreRecorder()
  let firstRunTodo = TodoItem(id: todoID(1), title: "Welcome", isCompleted: false)

  let cogs = Cogs.forTesting(mechanisms: [
    TodoMechanism(store: recorder.store, firstRunTodos: [firstRunTodo])
  ])

  let todoIDs = cogs.peek(todoIDsCog)
  let todoTitle = cogs.peek(todoTitleCogs[firstRunTodo.id])
  #expect(todoIDs == [firstRunTodo.id])
  #expect(todoTitle == "Welcome")
}

@MainActor
@Test func persistenceIgnoresDraftTypingAndSavesCommittedGraphState() throws {
  let todo = TodoItem(id: todoID(1), title: "Persist me", isCompleted: false)
  let recorder = TodoStoreRecorder()
  recorder.loaded = TodoSnapshot(todos: [todo], filter: .all)
  let cogs = Cogs.forTesting(mechanisms: [
    TodoMechanism(store: recorder.store, firstRunTodos: [])
  ])

  cogs.typeNewTodoTitle("Uncommitted")
  #expect(recorder.saved.isEmpty)

  cogs.toggleTodo(todo.id)
  let saved = try #require(recorder.saved.last)
  #expect(saved.todos == [TodoItem(id: todo.id, title: todo.title, isCompleted: true)])
  #expect(saved.filter == .all)
}

#endif
