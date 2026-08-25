import Cog
import SwiftUI

/// One keyed row whose title and completion observe only this todo's cells.
struct TodoRow: View {
  /// Singular graph inherited from ``TodoMVCApp``.
  @Environment(\.cogs) private var cogs
  /// Platform focus state for direct inline editing.
  @FocusState private var isEditingTitle: Bool

  /// Key shared by SwiftUI identity and both Cog boxes.
  let id: TodoID

  /// Renders and edits one row without observing any sibling's fields.
  var body: some View {
    let todoTitle = cogs[todoTitleCogs[id]]
    let todoIsCompleted = cogs[todoIsCompletedCogs[id]]

    HStack(spacing: 12) {
      Button {
        withAnimation(.snappy) { cogs.toggleTodo(id) }
      } label: {
        Image(systemName: todoIsCompleted ? "checkmark.circle.fill" : "circle")
          .font(.title2)
          .foregroundStyle(todoIsCompleted ? TodoTheme.accent : Color.secondary.opacity(0.55))
          .contentTransition(.symbolEffect(.replace))
      }
      .buttonStyle(.plain)
      .accessibilityLabel(todoIsCompleted ? "Mark active" : "Mark complete")
      .accessibilityValue(todoTitle)

      TextField("Todo title", text: cogs.todoTitleBinding(for: id))
        .font(.body.weight(.medium))
        .foregroundStyle(todoIsCompleted ? .secondary : .primary)
        .strikethrough(todoIsCompleted, color: .secondary)
        .focused($isEditingTitle)
        .submitLabel(.done)
        .onSubmit { cogs.commitTodoTitle(for: id) }
        .onChange(of: isEditingTitle) { wasEditing, isEditing in
          if wasEditing && !isEditing {
            cogs.commitTodoTitle(for: id)
          }
        }

      Button(role: .destructive) {
        withAnimation(.snappy) { cogs.removeTodo(id) }
      } label: {
        Image(systemName: "xmark")
          .font(.caption.bold())
          .foregroundStyle(.secondary)
          .frame(width: 32, height: 32)
          .background(.quaternary, in: Circle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Delete \(todoTitle)")
    }
    .padding(.horizontal, 15)
    .padding(.vertical, 13)
    .background(TodoTheme.card, in: RoundedRectangle(cornerRadius: 18))
    .overlay(alignment: .leading) {
      if todoIsCompleted {
        Capsule()
          .fill(TodoTheme.accent)
          .frame(width: 3)
          .padding(.vertical, 12)
      }
    }
    .contextMenu {
      Button(todoIsCompleted ? "Mark active" : "Mark complete") {
        cogs.toggleTodo(id)
      }
      Button("Delete", role: .destructive) {
        cogs.removeTodo(id)
      }
    }
    .accessibilityElement(children: .contain)
  }
}
