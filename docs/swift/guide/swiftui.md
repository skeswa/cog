# SwiftUI integration

_August 26, 2026_

SwiftUI sees ordinary `@Observable` values; Cog owns the graph behind them.
The integration conventions keep that boundary thin: views resolve the runtime
themselves, read flatly, mutate through named operations, and adapt to
SwiftUI's binding-shaped APIs in one dedicated file per cluster.

## Resolve `Cogs` in every consumer

The app or scene root retains the one runtime and installs it with
`.cogEnvironment(cogs)`. Every view that interacts with Cog declares the
environment itself:

```swift
struct TrailDetailContent: View {
  @Environment(\.cogs) private var cogs
  let trailID: TrailID
  …
}
```

A view never accepts, stores, or forwards `Cogs` through an initializer.
Intermediate views pass domain values and identities only — `TrailID`, not a
runtime, and not a bundle of pre-read values. Tests and previews host views
under the same `.cogEnvironment(cogs)` modifier with an isolated runtime
([Testing](./testing.md)).

This rule is what keeps view initializers honest: a view's dependencies are
its parameters plus the reads visible in its body, and nothing rides along
implicitly.

## Bodies read flatly

Reads in one `body` come from one settled turn, and each read registers its
own dependency, so a view is invalidated only by the values it actually used.
Follow the reading conventions as written for any other code
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
by design (decision record, [core design §10](../design/exploration.md)); each
app writes its own thin adapters in the cluster's `+Bindings.swift` file, and
every adapter has the same shape: a tracked getter, and a setter that calls a
named operation.

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

That shape is load-bearing:

- **System-driven mutation converges on the app's own operations.** A back
  gesture, an interactive sheet dismissal, and a `NavigationLink(value:)` push
  all enter the graph through the same named op a button would call. There is
  no second road into the sources.
- **Equal writes are free.** SwiftUI writes bindings redundantly; the turn
  discards writes of equal values, so the redundancy costs nothing and
  triggers nobody.
- **Optional-item bindings branch in the setter.** The `sheet(item:)` adapter
  maps `nil` to the dismiss op and a value to the present op, so both
  directions of modality remain named operations:

```swift
set: { sheet in
  if let sheet {
    self.present(sheet)
  } else {
    self.dismissSheet()
  }
}
```

## What stays view-local

Not every value belongs in the graph. Platform-shaped presentation state and
uncommitted drafts stay in the view:

- Trails' hike logger keeps its note in `@State private var note` while the
  user types, committing through `cogs.logHike(for:note:)` — the graph holds
  committed facts, not keystrokes.
- Weather's map keeps `MapCameraPosition` view-local, derived from the
  graph-owned `weatherMapLocationCog` — the domain fact is Cog state; the
  camera is platform state.

The dividing question: would another screen, a mechanism, or persistence ever
care about this value? If not, it is view state.

Effects that are useful only while one screen is visible belong to SwiftUI's
own lifetime tools — `.task` and `values` — rather than to a mechanism
([mechanisms §6.5](../design/mechanisms.md)).
