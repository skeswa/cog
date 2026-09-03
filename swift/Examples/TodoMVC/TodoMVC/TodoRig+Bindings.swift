import Cog
import SwiftUI

extension Cogs {
  /// Tracked binding for the new-todo composer.
  var newTodoTitleBinding: Binding<String> {
    Binding(
      get: {
        let newTodoTitle = self[newTodoTitleCog]
        return newTodoTitle
      },
      set: { self.typeNewTodoTitle($0) }
    )
  }

  /// Tracked binding for the selected TodoMVC filter.
  var todoFilterBinding: Binding<TodoFilter> {
    Binding(
      get: {
        let todoFilter = self[todoFilterCog]
        return todoFilter
      },
      set: { self.selectTodoFilter($0) }
    )
  }

  /// Tracked binding for one keyed row title.
  ///
  /// - Parameter id: Todo whose title the field edits.
  func todoTitleBinding(for id: TodoID) -> Binding<String> {
    Binding(
      get: {
        let todoTitle = self[todoTitleCogs[id]]
        return todoTitle
      },
      set: { self.editTodoTitle($0, for: id) }
    )
  }
}
