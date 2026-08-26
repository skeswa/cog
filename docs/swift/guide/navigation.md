# Navigation and deep linking

_August 26, 2026_

Navigation is ordinary graph state. There is no router object — a router is a
state island holding facts ("where is the user?") outside the one
authoritative graph, which is exactly what the singular-state principle
forbids. Instead, each navigation container is driven by its own source, and
everything else — deep linking, restoration, analytics, navigation-gated
effects — falls out of machinery the graph already has.

The worked proof is the
[Trails](https://github.com/skeswa/cog/tree/main/swift/Examples/Trails)
example; this chapter names its patterns.

## One source per container

Each navigation fact gets its own manual source in a `NavigationState`
cluster, so the UI invalidates precisely:

```swift
/// The selected tab.
private let _selectedTabCog = Cog<TrailTab>.Manual { .explore }
/// Each tab's navigation stack, keyed so tabs invalidate independently.
private let _tabPathCogs = CogBox<[TrailRoute], TrailTab>.Manual { [] }
/// The single presented modal layer, or `nil` when nothing is presented.
private let _presentedSheetCog = Cog<TrailSheet?>.Manual { nil }
```

- **Tab selection** is a plain enum cog.
- **Stacks** are a keyed box of route arrays, one key per tab. Pushing on one
  tab notices only that tab's path; every tab keeps its stack while others are
  selected.
- **Modality** is one optional enum cog. New modal surfaces extend the enum;
  boolean presentation flags do not appear. Presenting or dismissing
  invalidates no path reader.

Routes are small `Codable` values carrying identities, never loaded models:
`.trail(TrailID)`, not `.trail(Trail)`. Screens resolve identities to content
at render time, which is what makes a route constructible from a URL, storable
in a snapshot, and honest when content changes underneath it.

## Both roads converge on named ops

App-initiated navigation calls domain ops (`show`, `present`,
`showTrailInExplore`). System-initiated navigation — back buttons, pop
gestures, tab taps, interactive dismissal — writes through the binding
adapters, whose setters call those same ops
([SwiftUI integration](./swiftui.md)). Both roads land on the same sources,
so there is nothing to reconcile.

Standard platform behaviors fall out as one-liners in the ops. Reselecting the
current tab pops it to root, because the tab binding's setter lands in
`selectTab`, and popping is just writing an empty path:

```swift
func selectTab(_ tab: TrailTab) {
  turn { c in
    if c[_selectedTabCog] == tab {
      c[_tabPathCogs[tab]] = []
    } else {
      c[_selectedTabCog] = tab
    }
  }
}
```

## A deep link is a value; opening one is one turn

Model the URL grammar as a value type whose parser and printer are exact
inverses — `TrailDeepLink(url:)` and `.url` — testable without a graph. The
parser validates shape only; whether an identity still exists is decided at
resolution, so a stale link degrades softly instead of failing at parse time.

Resolution is a named op that writes the _entire_ destination — tab, full
stack, sheet — in one atomic turn:

```swift
case .trail(let trailID):
  guard let trail = TrailCatalog.trail(trailID) else { return }
  turn { c in
    c[_selectedTabCog] = .explore
    c[_tabPathCogs[TrailTab.explore]] = [.region(trail.regionID), .trail(trailID)]
    c[_presentedSheetCog] = nil
  }
```

No observer sees a halfway state — no wrong tab flashing past, no sheet
lingering over a changed stack. Resolution consults the catalog to build the
stack _beneath_ the destination, so a deep-linked screen arrives with a
working back button. The entry point is one modifier:
`.onOpenURL { cogs.open(url: $0) }`.

## Derive the current screen; effects hang off it

The single topmost screen is an automatic value over the navigation sources —
sheet, else top of the selected tab's path, else the tab root. Nothing stores
it, so it can never disagree with the sources. Two families of behavior
attach to it:

- **Analytics without instrumentation.** One mechanism watches
  `currentScreenCog` and observes every transition — tap, gesture, URL, or
  restoration — with no per-screen tracking calls. Trails' journal is this
  pattern with the analytics service replaced by a visible log.
- **Navigation-gated work.** A derived Bool over navigation state
  (`isLoggingHikeCog`) gates a `whenever` scope, so an effect lives exactly
  while a screen is presented, however it was presented
  ([Side effects](./side-effects.md)).

## Restoration is the same code path

Because navigation state is ordinary `Codable` state, it goes into the same
snapshot document as the domain ([Side effects](./side-effects.md)): the
selected tab, every tab's stack, and the presented sheet. The persistence
mechanism installs it during assembly, so the first rendered frame is the
restored screen.

Cold-launch deep links, warm in-app navigation, and relaunch restoration are
then one code path — all three are turns writing the same sources, and the
screens resolve whatever identities those sources carry. Keep genuinely
session-scoped facts (a half-typed search, the visit journal) out of the
snapshot deliberately: restore where the user was, not what they were
mid-doing.

## Testing navigation

Because none of this touches SwiftUI, the whole navigation model tests
headlessly: parse a URL, call `open`, and assert on `peek` reads of tab, path,
and sheet ([Testing](./testing.md)).
