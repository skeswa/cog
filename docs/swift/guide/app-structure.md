# Structuring an app

_August 26, 2026_

An app built on Cog has one runtime, one state layer organized into named file
families, and views that resolve everything they need from the environment.
This chapter covers the skeleton; later chapters fill in each part.

## One runtime, assembled once

Production code calls `Cogs.assemble(mechanisms:)` exactly once, at launch,
and retains the result for the life of the app. Assembly starts every
mechanism before it returns, so the world the first frame renders is already
the world the mechanisms set up.

```swift
@main
@MainActor
struct TrailsApp: App {
  private let cogs: Cogs

  init() {
    cogs = Cogs.assemble(mechanisms: [
      TrailPersistenceMechanism(store: .live),
      TrailJournalMechanism(),
      HikeTimerMechanism(),
    ])
  }

  var body: some Scene {
    WindowGroup {
      TrailsRoot()
        .cogEnvironment(cogs)
    }
  }
}
```

The rules around that one call:

- **The app entry point assembles and retains; it does not write.** Initial
  state belongs in a mechanism's `operate`, where writes settle before
  `assemble` returns ([Side effects](./side-effects.md)).
- **Mechanism order is meaningful.** `operate` runs in array order, and a
  write during one mechanism's `operate` settles before the next mechanism
  runs. Trails lists persistence first so the journal mechanism's first entry
  is the restored screen, not the resting default.
- **There is no global `Cogs.app`.** Features cannot create a production
  runtime; the app owns the one object assembly returned. Tests and previews
  create their own isolated runtimes ([Testing](./testing.md)) — those are
  separate app runtimes, not islands inside this one.

## State clusters and file families

Application state lives in file families named
`<Cluster>State+<Aspect>.swift`, one family per state cluster. A small app has
one cluster; Trails has two — `TrailState` for the domain and
`NavigationState` for navigation — and the pattern scales by adding clusters,
not by growing files.

The four aspects:

| File                | Holds                                                                                                                                              |
| ------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `+Model.swift`      | The value types the cluster's cogs, operations, and mechanisms manage and exchange: identities, records, snapshot documents, service capabilities. |
| `+Cogs.swift`       | The sources, projections, derived declarations, and the cluster's `CogOps` operations.                                                             |
| `+Bindings.swift`   | SwiftUI binding adapters ([SwiftUI integration](./swiftui.md)).                                                                                    |
| `+Mechanisms.swift` | The cluster's mechanisms and the capabilities they own ([Side effects](./side-effects.md)).                                                        |

Trails' state layer, in full:

```text
NavigationState+Model.swift       tab, route, sheet, screen vocabulary
NavigationState+Cogs.swift        tab / path / sheet sources, derived screen, nav ops
NavigationState+Bindings.swift    TabView, NavigationStack, sheet adapters
NavigationState+Mechanisms.swift  the screen-visit journal
TrailState+Model.swift            identities, hike entries, the snapshot document
TrailState+Cogs.swift             bookmarks, search, hike log, snapshot cog, domain ops
TrailState+Bindings.swift         the search-field adapter
TrailState+Mechanisms.swift       persistence and the gated hike timer
TrailCatalog.swift                immutable content — deliberately outside the family
```

Two properties make the layout worth keeping strict:

- **The layout itself records what is state and what is content.** Immutable
  fixtures that never enter the graph — Trails' `TrailCatalog` — stay outside
  the family. A reader can tell from the file listing alone which facts the
  graph owns.
- **Clusters keep sources private and still compose.** Each `+Cogs.swift`
  file keeps its manual sources `private` at file scope; cross-cluster
  operations compose by calling the other file's operation inside a turn body,
  where the nested turn joins ([Writing state](./writing-state.md)). File
  privacy is the access-control boundary, so the file split is also the write
  boundary.

## Views resolve, values flow down

The scene root installs the runtime once with `.cogEnvironment(cogs)`. Every
view that interacts with Cog declares `@Environment(\.cogs) private var cogs`
itself; a view never accepts, stores, or forwards `Cogs` through an
initializer. Intermediate views pass domain values and identities only —
a parent hands a child a `TrailID`, never a runtime or a bundle of reads.

Explicit `Cogs` parameters remain appropriate at non-view composition
boundaries: the mechanism list above, and isolated test harnesses.

## Where this is specified

The runtime model is [core design §2](../design/exploration.md); assembly and
mechanism ordering are [mechanisms §6.3](../design/mechanisms.md); the
environment rule is expanded in [SwiftUI integration](./swiftui.md).
