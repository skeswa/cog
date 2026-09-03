---
description: "One runtime assembled once, the rigs that hold state, and how views reach the graph."
---

# Structuring an app

An app built on Cog has three parts. There is one runtime. There is one state
layer, organized into rigs. And there are views, which get
everything they need from the environment. This chapter covers that skeleton;
later chapters fill in each part.

## One runtime, assembled once

Production code calls `Cogs.assemble(mechanisms:)` exactly once, at launch,
and keeps the result for the life of the app. Assembly starts every mechanism
before it returns. That means the first frame the app draws already shows the
world the mechanisms set up.

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
  state belongs in a mechanism's `operate` method, where writes finish before
  `assemble` returns ([Side effects](./side-effects.md)).
- **Mechanism order matters.** Each `operate` runs in array order. A write
  during one mechanism's `operate` finishes before the next mechanism runs.
  Trails lists persistence first so that the journal mechanism's first entry
  is the restored screen, not the default one.
- **There is no global `Cogs.app`.** Features cannot create a production
  runtime. The app owns the one object that assembly returned. Tests and
  previews create their own isolated runtimes ([Testing](./testing.md)).
  Those are separate app runtimes, not islands inside this one.

## Rigs

A **rig** is one unit of application state: a `<Rig>Rig` prefix and the four
files that share it, named `<Rig>Rig+<Aspect>.swift`. A small app has one rig.
Trails has two: `TrailRig` for the domain and `NavigationRig` for navigation.
When an app grows, add rigs — do not grow the files.

The four aspects:

| File                | Holds                                                                                                               |
| ------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `+Model.swift`      | The value types the rig's cogs, operations, and mechanisms work with: identities, records, snapshots, capabilities. |
| `+Cogs.swift`       | The sources, projections, derived declarations, and the rig's `CogOps` operations.                                  |
| `+Bindings.swift`   | SwiftUI binding adapters ([SwiftUI integration](./swiftui.md)).                                                     |
| `+Mechanisms.swift` | The rig's mechanisms and the capabilities they own ([Side effects](./side-effects.md)).                             |

Trails' state layer, in full:

```text
NavigationRig+Model.swift       tab, route, sheet, screen vocabulary
NavigationRig+Cogs.swift        tab / path / sheet sources, derived screen, nav ops
NavigationRig+Bindings.swift    TabView, NavigationStack, sheet adapters
NavigationRig+Mechanisms.swift  the screen-visit journal
TrailRig+Model.swift            identities, hike entries, the snapshot document
TrailRig+Cogs.swift             bookmarks, search, hike log, snapshot cog, domain ops
TrailRig+Bindings.swift         the search-field adapter
TrailRig+Mechanisms.swift       persistence and the gated hike timer
TrailCatalog.swift                immutable content — deliberately outside the rig
```

Two things make this layout worth keeping strict:

- **The layout itself records what is state and what is content.** Fixed
  content that never enters the graph — Trails' `TrailCatalog` — stays
  outside the rig. You can tell which facts the graph owns just by
  reading the file listing.
- **Rigs keep their sources private and still work together.** Each
  `+Cogs.swift` file marks its manual sources `private`, so only that file
  can write them. When an action must change state in two rigs, one rig's
  operation calls the other rig's operation inside its turn
  body, and the nested turn joins ([Writing state](./writing-state.md)). The
  file split is therefore also the write boundary.

## Views resolve, values flow down

The app or scene root installs the runtime once with `.cogEnvironment(cogs)`.
Every view that uses Cog declares the environment for itself:
`@Environment(\.cogs) private var cogs`. A view never accepts, stores, or
passes along `Cogs` through an initializer. Parent views pass plain values
and identities only — a parent hands a child a `TrailID`, never a runtime
and never a bundle of pre-read values.

Explicit `Cogs` parameters are still right at boundaries that are not views:
the mechanism list above, and isolated test harnesses.

## Where this is specified

The runtime model is [core design §2](../design/exploration.md). Assembly and
mechanism ordering are [mechanisms §6.3](../design/mechanisms.md). The
environment rule is expanded in [SwiftUI integration](./swiftui.md).
