# tracked-binding-adapters

A `Binding` over graph state is constructed inside a view, or a binding getter reads through `peek` instead of a tracked read.

## Why this rule exists

Cog vends no binding helper, so every binding over graph state is an app's own adapter and the convention supplies the shape the library does not. A getter that peeks registers no dependency, so the control renders once and then silently stops following the fact it displays — a failure that looks like a rendering bug rather than a read bug. Constructing bindings inline in views spreads the writable surface across the view layer, so no single file answers what the system may mutate, which is the reason the adapters were collected onto the runtime in the first place.

## How to fix it

Move the binding into the state cluster's `+Bindings.swift` file as a member of `extension Cogs`, and give it the one adapter shape: a getter that reads with the tracked subscript, and a setter that calls a named `CogOps` operation. Call that adapter from the view.

<!-- Generated from the tracked-binding-adapters CogLint fixture corpus; do not edit. -->

## Triggering examples

### Bindings assembled inside a view

A binding whose closures touch the runtime is a writable surface, and every one of those belongs in the adapter file rather than in a body.

Expected diagnostic positions: 8:18, 12:26.

```swift
struct FilterBar: View {
  @Environment(\.cogs) private var cogs

  var body: some View {
    let todoFilter = cogs[todoFilterCog]
    Picker(
      "Filter",
      selection: Binding(get: { todoFilter }, set: { cogs.selectTodoFilter($0) })
    ) {
      Text("All")
    }
    Toggle("Done", isOn: Binding(get: { cogs[isDoneCog] }, set: { cogs.setDone($0) }))
  }
}
```

### Adapter getters that peek

Bare and `self`-qualified peeks both read without registering, so the control never learns the value changed.

Expected diagnostic positions: 4:19, 9:20.

```swift
extension Cogs {
  var searchQueryBinding: Binding<String> {
    Binding(
      get: { self.peek(searchQueryCog) },
      set: { self.typeSearchQuery($0) }
    )
  }
  func draftBinding(for id: TodoID) -> Binding<String> {
    Binding(get: { peek(draftCogs[id]) }, set: { self.editDraft($0, for: id) })
  }
}
```

### Status-lens peek through an explicit initializer

The status lens is the same untracked read, and a generically specialized `.init` still names `Binding` in source.

Expected diagnostic positions: 4:26.

```swift
extension Cogs {
  var currentZipBinding: Binding<ZipCode?> {
    Binding<ZipCode?>.init(
      get: { self.status.peek(currentZipCog).value },
      set: { self.selectCurrentLocation($0) }
    )
  }
}
```

## Non-triggering examples

### Conforming runtime adapters

Each adapter pairs a tracked getter with a named operation, which is the one shape the convention asks for.

```swift
extension Cogs {
  var todoFilterBinding: Binding<TodoFilter> {
    Binding(
      get: {
        let todoFilter = self[todoFilterCog]
        return todoFilter
      },
      set: { self.selectTodoFilter($0) }
    )
  }
  func tabPathBinding(for tab: TrailTab) -> Binding<[TrailRoute]> {
    Binding(
      get: {
        let tabPath = self[tabPathCogs[tab]]
        return tabPath
      },
      set: { self.setPath($0, in: tab) }
    )
  }
}
```

### Views that call adapters and bind local state

A view may build bindings over its own `@State`; only bindings that reach the runtime are collected.

```swift
struct ComposerField: View {
  @Environment(\.cogs) private var cogs
  @State private var draft = ""

  var body: some View {
    let newTodoTitle = cogs[newTodoTitleCog]
    TextField("Draft", text: Binding(get: { draft }, set: { draft = $0 }))
    TextField("Todo", text: cogs.newTodoTitleBinding)
    Text(newTodoTitle)
  }
}
```

### Setter peeks and non-constructed bindings

Only the getter must register, and projections and factory members name no construction to inspect.

```swift
extension Cogs {
  var quantityBinding: Binding<Int> {
    Binding(
      get: {
        let quantity = self[quantityCog]
        return quantity
      },
      set: { self.changeQuantity(to: $0, from: self.peek(quantityCog)) }
    )
  }
}
struct QuantityStepper: View {
  @State private var draft = Draft()

  var body: some View {
    Stepper("Quantity", value: $draft.quantity)
    Toggle("Locked", isOn: .constant(true))
  }
}
```

## Accepted evasions

### Bindings outside recognizable views and receivers

A `View` conformance written in another file hides the placement policy, and an explicitly passed `Cogs` parameter is not a classified receiver, so neither peek nor placement is provable here.

```swift
struct SavedToggle {
  @Environment(\.cogs) private var cogs

  var savedBinding: Binding<Bool> {
    Binding(get: { self.cogs[isSavedCog] }, set: { self.cogs.setSaved($0) })
  }
}

func untrackedBinding(_ cogs: Cogs) -> Binding<Bool> {
  Binding(get: { cogs.peek(isSavedCog) }, set: { _ in })
}
```
