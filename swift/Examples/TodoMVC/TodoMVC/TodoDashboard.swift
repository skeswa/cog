import Cog
import SwiftUI

/// The native iOS interpretation of the classic TodoMVC screen.
struct TodoDashboard: View {
  /// Singular graph inherited from ``TodoMVCApp``.
  @Environment(\.cogs) private var cogs

  /// Renders the composer, summary, classic filters, and keyed rows.
  var body: some View {
    let todoIDs = cogs[todoIDsCog]
    let visibleTodoIDs = cogs[visibleTodoIDsCog]
    let todoFilter = cogs[todoFilterCog]

    NavigationStack {
      ScrollView {
        LazyVStack(spacing: 16) {
          TodoHero()
          TodoComposer()

          if !todoIDs.isEmpty {
            TodoSummaryCard()
            TodoFilterBar()
          }

          if visibleTodoIDs.isEmpty {
            TodoEmptyState(filter: todoFilter)
          } else {
            LazyVStack(spacing: 10) {
              ForEach(visibleTodoIDs) { id in
                TodoRow(id: id)
              }
            }
          }

          if !todoIDs.isEmpty {
            TodoFooter()
          }
        }
        .frame(maxWidth: 680)
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 36)
        .frame(maxWidth: .infinity)
      }
      .background(TodoTheme.background.ignoresSafeArea())
      .navigationBarHidden(true)
    }
  }
}

/// Brand header that nods to the original TodoMVC typography.
private struct TodoHero: View {
  /// Displays the example title and its purpose.
  var body: some View {
    VStack(spacing: 2) {
      Text("todos")
        .font(.system(size: 64, weight: .ultraLight, design: .rounded))
        .foregroundStyle(TodoTheme.accent)
        .accessibilityAddTraits(.isHeader)

      Text("A fine-grained Cog state graph")
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary)
    }
    .padding(.bottom, 4)
  }
}

/// New-todo field backed by the graph's singular composer source.
private struct TodoComposer: View {
  /// Runtime resolved directly at this input boundary.
  @Environment(\.cogs) private var cogs
  /// Platform focus state; it is not domain state and stays local to the field.
  @FocusState private var isFocused: Bool

  /// Adds a trimmed todo on submit or button tap.
  var body: some View {
    let newTodoTitle = cogs[newTodoTitleCog]

    HStack(spacing: 12) {
      Image(systemName: "plus")
        .font(.headline)
        .foregroundStyle(TodoTheme.accent)
        .frame(width: 36, height: 36)
        .background(TodoTheme.accent.opacity(0.1), in: Circle())
        .accessibilityHidden(true)

      TextField("What needs to be done?", text: cogs.newTodoTitleBinding)
        .font(.body)
        .focused($isFocused)
        .submitLabel(.done)
        .onSubmit(addTodo)

      Button(action: addTodo) {
        Image(systemName: "arrow.up")
          .font(.subheadline.bold())
          .foregroundStyle(.white)
          .frame(width: 34, height: 34)
          .background(TodoTheme.accent, in: Circle())
      }
      .buttonStyle(.plain)
      .disabled(newTodoTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      .opacity(newTodoTitle.isEmpty ? 0.42 : 1)
      .accessibilityLabel("Add todo")
    }
    .padding(14)
    .background(TodoTheme.card, in: RoundedRectangle(cornerRadius: 22))
    .shadow(color: TodoTheme.shadow, radius: 18, y: 8)
    .contentShape(Rectangle())
    .onTapGesture { isFocused = true }
  }

  /// Commits through the domain operation and keeps rapid entry focused.
  private func addTodo() {
    cogs.addTodo()
    isFocused = true
  }
}

/// Completion totals and the classic toggle-all action.
private struct TodoSummaryCard: View {
  /// Runtime resolved directly by the summary boundary.
  @Environment(\.cogs) private var cogs

  /// Shows equality-gated derived counts and overall progress.
  var body: some View {
    let todoIDs = cogs[todoIDsCog]
    let activeTodoCount = cogs[activeTodoCountCog]
    let completedTodoCount = cogs[completedTodoCountCog]
    let allTodosCompleted = cogs[allTodosCompletedCog]
    let progress = Double(completedTodoCount) / Double(todoIDs.count)

    VStack(spacing: 14) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text(activeTodoCount == 1 ? "1 item left" : "\(activeTodoCount) items left")
            .font(.headline)
            .contentTransition(.numericText())

          Text("\(completedTodoCount) of \(todoIDs.count) complete")
            .font(.caption)
            .foregroundStyle(.secondary)
            .contentTransition(.numericText())
        }

        Spacer()

        Button {
          withAnimation(.snappy) { cogs.toggleAllTodos() }
        } label: {
          Label(
            allTodosCompleted ? "Mark all active" : "Complete all",
            systemImage: allTodosCompleted ? "arrow.uturn.backward.circle" : "checkmark.circle"
          )
        }
        .font(.subheadline.weight(.semibold))
        .buttonStyle(.bordered)
        .tint(TodoTheme.accent)
      }

      ProgressView(value: progress)
        .tint(TodoTheme.accent)
        .accessibilityLabel("Todo completion")
        .accessibilityValue("\(completedTodoCount) of \(todoIDs.count)")
    }
    .padding(16)
    .background(TodoTheme.accent.opacity(0.075), in: RoundedRectangle(cornerRadius: 20))
  }
}

/// Segmented All, Active, and Completed selector.
private struct TodoFilterBar: View {
  /// Runtime resolved directly by the filter input.
  @Environment(\.cogs) private var cogs

  /// Writes the selected filter through a tracked Cog binding.
  var body: some View {
    Picker("Filter todos", selection: cogs.todoFilterBinding) {
      ForEach(TodoFilter.allCases) { filter in
        Text(filter.label).tag(filter)
      }
    }
    .pickerStyle(.segmented)
    .accessibilityHint("Choose which todos are shown")
  }
}

/// Filter-aware empty state used both before entry and for empty subsets.
private struct TodoEmptyState: View {
  /// Selected subset whose absence is being explained.
  let filter: TodoFilter

  /// Shows calm, specific guidance without introducing graph state.
  var body: some View {
    ContentUnavailableView(
      filter.emptyTitle,
      systemImage: filter.emptySymbol,
      description: Text(filter.emptyMessage)
    )
    .frame(minHeight: 210)
    .frame(maxWidth: .infinity)
    .background(TodoTheme.card.opacity(0.72), in: RoundedRectangle(cornerRadius: 22))
  }
}

/// Clear-completed affordance and small interaction hint.
private struct TodoFooter: View {
  /// Runtime resolved directly by the destructive action boundary.
  @Environment(\.cogs) private var cogs

  /// Shows clear only when useful and keeps the edit gesture discoverable.
  var body: some View {
    let completedTodoCount = cogs[completedTodoCountCog]

    HStack {
      Label("Tap a title to edit", systemImage: "pencil")
        .font(.caption)
        .foregroundStyle(.secondary)

      Spacer()

      if completedTodoCount > 0 {
        Button("Clear completed") {
          withAnimation(.snappy) { cogs.clearCompletedTodos() }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(TodoTheme.accent)
        .accessibilityLabel("Clear \(completedTodoCount) completed todos")
      }
    }
    .padding(.horizontal, 4)
  }
}

/// Shared visual constants for the TodoMVC example.
enum TodoTheme {
  /// Classic TodoMVC red, deepened for contrast on iOS surfaces.
  static let accent = Color(red: 0.73, green: 0.20, blue: 0.34)
  /// Adaptive grouped canvas behind the centered document.
  static let background = Color(uiColor: .systemGroupedBackground)
  /// Adaptive raised surface for composer, rows, and empty states.
  static let card = Color(uiColor: .secondarySystemGroupedBackground)
  /// Restrained elevation shadow that disappears naturally in dark mode.
  static let shadow = Color.black.opacity(0.08)
}
