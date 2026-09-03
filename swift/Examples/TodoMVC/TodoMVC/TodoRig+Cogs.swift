import Cog

// The Todo rig's declarations and ops. TodoMVC's state is deliberately split
// by update shape. Membership is an ordered keyless value; row fields are
// keyed values. A row edit therefore notices only that row, while list
// operations can still change several facts atomically in one turn.

/// Ordered membership for the list.
private let _todoIDsCog = Cog<[TodoID]>.Manual { [] }
/// Text currently typed into the new-todo composer.
private let _newTodoTitleCog = Cog<String>.Manual { "" }
/// Selected TodoMVC visibility filter.
private let _todoFilterCog = Cog<TodoFilter>.Manual { .all }
/// User-authored titles, stored independently per todo.
private let _todoTitleCogs = CogBox<String, TodoID>.Manual { "" }
/// Completion flags, stored independently per todo.
private let _todoIsCompletedCogs = CogBox<Bool, TodoID>.Manual { false }

/// Ordered todo identities.
let todoIDsCog = _todoIDsCog.readOnly
/// Current composer text.
let newTodoTitleCog = _newTodoTitleCog.readOnly
/// Current visibility filter.
let todoFilterCog = _todoFilterCog.readOnly
/// Read-only title for each todo identity.
let todoTitleCogs = _todoTitleCogs.readOnly
/// Read-only completion state for each todo identity.
let todoIsCompletedCogs = _todoIsCompletedCogs.readOnly

/// Todo identities admitted by the current filter.
///
/// The `.all` branch returns before reading any keyed completion value. While
/// All is selected, toggling a row therefore invalidates that row and the
/// summary, but not the list container. Active and Completed intentionally add
/// dynamic edges to completion values because membership then depends on them.
let visibleTodoIDsCog = Cog<[TodoID]> { c in
  let todoIDs = c[todoIDsCog]
  let todoFilter = c[todoFilterCog]
  guard todoFilter != .all else { return todoIDs }

  return todoIDs.filter { id in
    let todoIsCompleted = c[todoIsCompletedCogs[id]]
    return todoFilter == .completed ? todoIsCompleted : !todoIsCompleted
  }
}

/// Number of incomplete todos across every filter.
let activeTodoCountCog = Cog<Int> { c in
  let todoIDs = c[todoIDsCog]
  return todoIDs.reduce(into: 0) { count, id in
    let todoIsCompleted = c[todoIsCompletedCogs[id]]
    if !todoIsCompleted { count += 1 }
  }
}

/// Number of completed todos across every filter.
let completedTodoCountCog = Cog<Int> { c in
  let todoIDs = c[todoIDsCog]
  return todoIDs.reduce(into: 0) { count, id in
    let todoIsCompleted = c[todoIsCompletedCogs[id]]
    if todoIsCompleted { count += 1 }
  }
}

/// Whether a nonempty list is entirely complete.
let allTodosCompletedCog = Cog<Bool> { c in
  let todoIDs = c[todoIDsCog]
  guard !todoIDs.isEmpty else { return false }
  let activeTodoCount = c[activeTodoCountCog]
  return activeTodoCount == 0
}

/// Whole-value document observed only by the persistence mechanism.
///
/// UI rows read their keyed values directly. Keeping this aggregate away from
/// the UI preserves row-granular invalidation while still giving storage one
/// coherent snapshot from a completed turn.
let todoSnapshotCog = Cog<TodoSnapshot> { c in
  let todoIDs = c[todoIDsCog]
  let todoFilter = c[todoFilterCog]
  let todos = todoIDs.map { id in
    let todoTitle = c[todoTitleCogs[id]]
    let todoIsCompleted = c[todoIsCompletedCogs[id]]
    return TodoItem(id: id, title: todoTitle, isCompleted: todoIsCompleted)
  }
  return TodoSnapshot(todos: todos, filter: todoFilter)
}

extension CogOps {
  /// Installs a complete starting document during mechanism assembly.
  ///
  /// - Parameters:
  ///   - todos: Ordered rows to install.
  ///   - filter: Visibility selection to restore.
  func installTodos(_ todos: [TodoItem], filter: TodoFilter) {
    turn { c in
      c[_todoIDsCog] = todos.map(\.id)
      c[_todoFilterCog] = filter
      c[_newTodoTitleCog] = ""
      for todo in todos {
        c[_todoTitleCogs[todo.id]] = todo.title
        c[_todoIsCompletedCogs[todo.id]] = todo.isCompleted
      }
    }
  }

  /// Replaces the composer text with the field's latest value.
  ///
  /// - Parameter title: Uncommitted text, including any surrounding whitespace.
  func typeNewTodoTitle(_ title: String) {
    turn(_newTodoTitleCog, to: title)
  }

  /// Commits the composer as a new row and clears it in one settled turn.
  ///
  /// Blank normalized titles do nothing, matching TodoMVC. UI callers use the
  /// default fresh UUID, while other callers may supply an identity.
  ///
  /// - Parameter id: Identity for the row being created.
  func addTodo(id: TodoID = TodoID()) {
    turn { c in
      let newTodoTitle = c[_newTodoTitleCog].normalizedTodoTitle
      guard !newTodoTitle.isEmpty else { return }

      c[_todoIDsCog] = c[_todoIDsCog] + [id]
      c[_todoTitleCogs[id]] = newTodoTitle
      c[_todoIsCompletedCogs[id]] = false
      c[_newTodoTitleCog] = ""
    }
  }

  /// Toggles one row from its staged completion value.
  ///
  /// - Parameter id: Todo whose completion changes.
  func toggleTodo(_ id: TodoID) {
    turn { c in
      c[_todoIsCompletedCogs[id]] = !c[_todoIsCompletedCogs[id]]
    }
  }

  /// Writes the current inline title without creating a second edit buffer.
  ///
  /// - Parameters:
  ///   - title: Field text as the user types it.
  ///   - id: Todo being edited.
  func editTodoTitle(_ title: String, for id: TodoID) {
    turn(_todoTitleCogs[id], to: title)
  }

  /// Normalizes an edited title, removing the todo when the result is blank.
  ///
  /// - Parameter id: Todo whose inline edit is ending.
  func commitTodoTitle(for id: TodoID) {
    turn { c in
      let todoTitle = c[_todoTitleCogs[id]].normalizedTodoTitle
      if todoTitle.isEmpty {
        c[_todoIDsCog] = c[_todoIDsCog].filter { $0 != id }
      } else {
        c[_todoTitleCogs[id]] = todoTitle
      }
    }
  }

  /// Removes one todo from ordered membership.
  ///
  /// Its unreachable keyed cells can be reclaimed by normal Cog lifetime
  /// rules; membership remains the one authoritative enumeration.
  ///
  /// - Parameter id: Todo to remove.
  func removeTodo(_ id: TodoID) {
    turn { c in
      c[_todoIDsCog] = c[_todoIDsCog].filter { $0 != id }
    }
  }

  /// Completes every todo when any are active, otherwise reactivates them all.
  func toggleAllTodos() {
    turn { c in
      let todoIDs = c[_todoIDsCog]
      let shouldComplete = todoIDs.contains { !c[_todoIsCompletedCogs[$0]] }
      for id in todoIDs {
        c[_todoIsCompletedCogs[id]] = shouldComplete
      }
    }
  }

  /// Removes every completed todo in one membership write.
  func clearCompletedTodos() {
    turn { c in
      c[_todoIDsCog] = c[_todoIDsCog].filter { !c[_todoIsCompletedCogs[$0]] }
    }
  }

  /// Selects the TodoMVC subset visible on screen.
  ///
  /// - Parameter filter: New visibility filter.
  func selectTodoFilter(_ filter: TodoFilter) {
    turn(_todoFilterCog, to: filter)
  }
}
