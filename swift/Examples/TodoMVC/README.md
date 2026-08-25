# Cog TodoMVC

This is the classic TodoMVC feature as a native SwiftUI app. It implements the
full interaction set—add, edit, complete, delete, toggle all, clear completed,
and All/Active/Completed filters—while making Cog's fine-grained update shape
easy to inspect.

Open `TodoMVC.xcodeproj`, or build it from the repository:

```sh
mise run build:todomvc
```

## What it demonstrates

- `TodoMVCApp` assembles and retains one app-wide `Cogs` runtime.
- `TodoState+Cogs.swift` keeps ordered membership in one manual cog and each row's
  title and completion in keyed manual boxes. Editing one row therefore does
  not invalidate another.
- `visibleTodoIDsCog` changes its dependencies with the selected filter. Under
  All it does not read completion at all; under Active or Completed it tracks
  exactly the keyed completion values that decide membership.
- Counts, toggle-all state, and the persistence document are automatic values,
  equality-gated independently from the rows.
- Every mutation is a domain operation on `CogOps`. Multi-value actions such as
  adding a row and clearing the composer settle in one turn.
- `TodoState+Bindings.swift` keeps SwiftUI adapters separate from graph
  declarations and domain operations.
- `TodoState+Mechanisms.swift` restores persisted JSON during assembly and
  owns the one persistence reaction. `UserDefaults` is durable storage, not a
  second live source of truth.
- Every Cog-consuming view resolves `Cogs` from the environment and reads its
  dependencies flatly. Parents pass only `TodoID` values.

The interface is an iOS-native interpretation of TodoMVC rather than a web view:
titles edit inline, all controls have accessibility labels, the layout adapts to
iPhone and iPad widths, and the palette follows light and dark mode.
