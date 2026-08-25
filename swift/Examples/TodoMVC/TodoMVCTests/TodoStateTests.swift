#if DEBUG

import Cog
import CogTesting
import Testing

@MainActor
@Test func addingATodoNormalizesItsTitleAndClearsTheComposerInOneTurn() {
  let id = todoID(1)
  let cogs = Cogs.forTesting()

  cogs.typeNewTodoTitle("  Learn Cog\n")
  let turnsBeforeAdd = cogs.debugHistory.entries.count { $0.event == .turn }
  cogs.addTodo(id: id)

  let todoIDs = cogs.peek(todoIDsCog)
  let todoTitle = cogs.peek(todoTitleCogs[id])
  let todoIsCompleted = cogs.peek(todoIsCompletedCogs[id])
  let newTodoTitle = cogs.peek(newTodoTitleCog)
  #expect(todoIDs == [id])
  #expect(todoTitle == "Learn Cog")
  #expect(todoIsCompleted == false)
  #expect(newTodoTitle.isEmpty)

  let turnsAfterAdd = cogs.debugHistory.entries.count { $0.event == .turn }
  #expect(turnsAfterAdd == turnsBeforeAdd + 1)
}

@MainActor
@Test func blankComposerInputDoesNotCreateATodo() {
  let cogs = Cogs.forTesting()
  cogs.typeNewTodoTitle(" \n\t ")
  cogs.addTodo(id: todoID(1))

  let todoIDs = cogs.peek(todoIDsCog)
  let newTodoTitle = cogs.peek(newTodoTitleCog)
  #expect(todoIDs.isEmpty)
  #expect(newTodoTitle == " \n\t ")
}

@MainActor
@Test func filtersAndCountsFollowKeyedCompletionState() {
  let first = TodoItem(id: todoID(1), title: "First", isCompleted: false)
  let second = TodoItem(id: todoID(2), title: "Second", isCompleted: true)
  let third = TodoItem(id: todoID(3), title: "Third", isCompleted: false)
  let cogs = Cogs.forTesting(seeding: { $0.seedTodos([first, second, third]) })

  let initialActiveTodoCount = cogs.peek(activeTodoCountCog)
  let initialCompletedTodoCount = cogs.peek(completedTodoCountCog)
  #expect(initialActiveTodoCount == 2)
  #expect(initialCompletedTodoCount == 1)

  cogs.selectTodoFilter(.active)
  let activeTodoIDs = cogs.peek(visibleTodoIDsCog)
  #expect(activeTodoIDs == [first.id, third.id])

  cogs.selectTodoFilter(.completed)
  let completedTodoIDs = cogs.peek(visibleTodoIDsCog)
  #expect(completedTodoIDs == [second.id])

  cogs.toggleTodo(first.id)
  let changedCompletedTodoIDs = cogs.peek(visibleTodoIDsCog)
  let changedActiveTodoCount = cogs.peek(activeTodoCountCog)
  let changedCompletedTodoCount = cogs.peek(completedTodoCountCog)
  #expect(changedCompletedTodoIDs == [first.id, second.id])
  #expect(changedActiveTodoCount == 1)
  #expect(changedCompletedTodoCount == 2)
}

@MainActor
@Test func toggleAllAndClearCompletedApplyWholeListActions() {
  let first = TodoItem(id: todoID(1), title: "First", isCompleted: false)
  let second = TodoItem(id: todoID(2), title: "Second", isCompleted: true)
  let cogs = Cogs.forTesting(seeding: { $0.seedTodos([first, second]) })

  cogs.toggleAllTodos()
  let allTodosCompleted = cogs.peek(allTodosCompletedCog)
  let firstIsCompleted = cogs.peek(todoIsCompletedCogs[first.id])
  let secondIsCompleted = cogs.peek(todoIsCompletedCogs[second.id])
  #expect(allTodosCompleted)
  #expect(firstIsCompleted)
  #expect(secondIsCompleted)

  cogs.toggleAllTodos()
  let noTodosCompleted = cogs.peek(completedTodoCountCog)
  #expect(noTodosCompleted == 0)

  cogs.toggleTodo(second.id)
  cogs.clearCompletedTodos()
  let remainingTodoIDs = cogs.peek(todoIDsCog)
  #expect(remainingTodoIDs == [first.id])
}

@MainActor
@Test func committingABlankInlineTitleRemovesTheTodo() {
  let todo = TodoItem(id: todoID(1), title: "Temporary", isCompleted: false)
  let cogs = Cogs.forTesting(seeding: { $0.seedTodos([todo]) })

  cogs.editTodoTitle("   ", for: todo.id)
  cogs.commitTodoTitle(for: todo.id)

  let todoIDs = cogs.peek(todoIDsCog)
  #expect(todoIDs.isEmpty)
}

#endif
