---
description: "Resolving Cogs from the environment, flat reads in bodies, tracked binding adapters, and what stays view-local."
---

# SwiftUI integration

SwiftUI sees ordinary `@Observable` values; Cog owns the graph behind them.
The integration conventions keep that boundary thin. Views resolve the
runtime themselves, read flatly, mutate through named operations, and adapt
to SwiftUI's binding-shaped APIs in one dedicated file per cluster.

## Resolve `Cogs` in every consumer

The app or scene root retains the one runtime and installs it with
`.cogEnvironment(cogs)`. Every view that uses Cog declares the environment
itself:

```swift
struct TrailDetailContent: View {
  @Environment(\.cogs) private var cogs
  let trailID: TrailID
  …
}
```

A view never accepts, stores, or forwards `Cogs` through an initializer.
Parent views pass plain values and identities only — a `TrailID`, not a
runtime, and not a bundle of pre-read values. Tests and previews host views
under the same `.cogEnvironment(cogs)` modifier with an isolated runtime
([Testing](./testing.md)).

This rule keeps view initializers honest. A view's dependencies are its
parameters plus the reads visible in its body, and nothing rides along
hidden.

## Bodies read flatly

Reads in one `body` come from one settled turn, and each read registers its
own dependency. So a view is invalidated only by the values it actually
used. Follow the reading conventions exactly as in any other code
([Reading state](./reading-state.md)): one read per line, unwrapped into a
domain local, keyed reads for per-row facts.

```swift
var body: some View {
  let isTrailSaved = cogs[isTrailSavedCogs[trailID]]
  let hikeCount = cogs[hikeCountCogs[trailID]]
  …
}
```

## Bindings adapt, in one place, through named ops

SwiftUI's container APIs — `TabView`, `NavigationStack(path:)`,
`sheet(item:)`, `.searchable` — speak `Binding`. Cog ships no binding helper
on purpose (decision record, [core design §10](../design/exploration.md)).
Each app writes its own thin adapters in the cluster's `+Bindings.swift`
file, and every adapter has the same shape: a tracked getter, and a setter
that calls a named operation. `coglint`'s `tracked-binding-adapters` rule
enforces that shape, so the library ships the convention even though it ships
no helper.

```swift
extension Cogs {
  /// Tracked binding for one tab's `NavigationStack` path.
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

That shape carries three guarantees:

- **System-driven mutation lands on the app's own operations.** A back
  gesture, an interactive sheet dismissal, and a `NavigationLink(value:)`
  push all enter the graph through the same named op a button would call.
  There is no second road into the sources.
- **Equal writes are free.** SwiftUI writes bindings redundantly. The turn
  discards writes of equal values, so the redundancy costs nothing and
  triggers nobody.
- **Optional-item bindings branch in the setter.** The `sheet(item:)`
  adapter maps `nil` to the dismiss op and a value to the present op, so
  both directions of modality stay named operations:

```swift
set: { sheet in
  if let sheet {
    self.present(sheet)
  } else {
    self.dismissSheet()
  }
}
```

Two mistakes are worth naming because neither is a compile error. A getter
written with `peek` reads without registering, so the control renders once and
then quietly stops following its own value. And a binding assembled inline in a
view puts a writable surface outside the one file that is supposed to list
them. The lint rule rejects both.

## What stays view-local

Not every value belongs in the graph. Platform-shaped presentation state and
uncommitted drafts stay in the view:

- Trails' hike logger keeps its note in `@State private var note` while the
  user types, and commits through `cogs.logHike(for:note:)`. The graph holds
  committed facts, not keystrokes.
- Weather's map keeps `MapCameraPosition` view-local, derived from the
  graph-owned `weatherMapLocationCog`. The domain fact is Cog state; the
  camera is platform state.

The dividing question: would another screen, a mechanism, or persistence
ever care about this value? If not, it is view state.

An effect that is useful only while one screen is visible belongs to
SwiftUI's own lifetime tools — `.task` and `values` — rather than to a
mechanism ([mechanisms §6.5](../design/mechanisms.md)).
