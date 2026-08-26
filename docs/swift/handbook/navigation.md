# Navigation and deep linking

_August 26, 2026_

Navigation is ordinary graph state. There is no router object. A router
would hold facts — "where is the user?" — outside the one authoritative
graph, and that is exactly what the singular-state principle forbids.
Instead, each navigation container is driven by its own source. Deep
linking, restoration, analytics, and navigation-gated effects then fall out
of machinery the graph already has.

The sketches below use a generic app with tabs, an item catalog, and one
modal sheet. The
[Trails](https://github.com/skeswa/cog/tree/main/swift/Examples/Trails)
example implements every pattern in this chapter as a working app.

## One source per container

Each navigation fact gets its own manual source in a `NavigationState`
cluster, so the UI updates precisely:

```swift
/// The selected tab.
private let _selectedTabCog = Cog<AppTab>.Manual { .home }
/// Each tab's navigation stack, keyed so tabs invalidate independently.
private let _tabPathCogs = CogBox<[Route], AppTab>.Manual { [] }
/// The single presented modal layer, or `nil` when nothing is presented.
private let _presentedSheetCog = Cog<Sheet?>.Manual { nil }
```

- **Tab selection** is a plain enum cog.
- **Stacks** are a keyed box of route arrays, one key per tab. Pushing on
  one tab touches only that tab's path, and every tab keeps its stack while
  other tabs are selected.
- **Modality** is one optional enum cog. A new modal surface becomes a new
  enum case — never a Boolean "is presented" flag. Presenting or dismissing
  touches no path at all.

Routes are small `Codable` values that carry identities, never loaded
models: `.detail(ItemID)`, not `.detail(Item)`. Screens look the content up
at render time. That is what makes a route buildable from a URL, storable in
a snapshot, and honest when the content changes underneath it.

## Both roads converge on named ops

App code navigates by calling domain ops (`show`, `present`, and friends).
The system navigates — back buttons, pop gestures, tab taps,
swipe-to-dismiss — by writing through the binding adapters, whose setters
call those same ops ([SwiftUI integration](./swiftui.md)). Both roads land
on the same sources, so there is nothing to keep in sync.

Standard platform behaviors become one-liners in the ops. Reselecting the
current tab pops it to its root, because the tab binding's setter lands in
`selectTab`, and popping is just writing an empty path:

```swift
func selectTab(_ tab: AppTab) {
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
inverses — `DeepLink(url:)` and `.url`. Both are testable without a graph.
The parser checks shape only. Whether an identity still exists is decided
later, at resolution, so a stale link fails softly instead of failing at
parse time.

Resolution is a named op that writes the _entire_ destination — tab, full
stack, sheet — in one atomic turn:

```swift
case .detail(let itemID):
  guard let item = catalog.item(itemID) else { return }
  turn { c in
    c[_selectedTabCog] = .home
    c[_tabPathCogs[AppTab.home]] = [.collection(item.collectionID), .detail(itemID)]
    c[_presentedSheetCog] = nil
  }
```

No observer sees a halfway state — no wrong tab flashing past, no sheet
hanging over a changed stack. Resolution consults the app's content to build
the stack _beneath_ the destination, so a deep-linked screen arrives with a
working back button. The entry point is one modifier:
`.onOpenURL { cogs.open(url: $0) }`.

## Derive the current screen; effects hang off it

The single topmost screen is an automatic value over the navigation
sources: the sheet if one is up, else the top of the selected tab's path,
else the tab root. Nothing stores it, so it can never disagree with the
sources. Two kinds of behavior attach to it:

- **Analytics without instrumentation.** One mechanism watches
  `currentScreenCog` and sees every transition — tap, gesture, URL, or
  restoration — with no per-screen tracking calls. Trails demonstrates this
  with the analytics service replaced by a visible journal.
- **Navigation-gated work.** A derived Bool over navigation state — "is
  this sheet up?", "is this screen showing?" — gates a `whenever` scope, so
  an effect lives exactly while a screen is presented, however it was
  presented ([Side effects](./side-effects.md)).

## Restoration is the same code path

Navigation state is ordinary `Codable` state, so it goes into the same
snapshot document as the domain ([Side effects](./side-effects.md)): the
selected tab, every tab's stack, and the presented sheet. The persistence
mechanism installs it during assembly, so the first rendered frame is the
restored screen.

Cold-launch deep links, warm in-app navigation, and relaunch restoration
become one code path. All three are turns writing the same sources, and the
screens resolve whatever identities those sources carry. Keep genuinely
session-scoped facts — a half-typed search, a transient log — out of the
snapshot on purpose: restore where the user was, not what they were
mid-doing.

## Testing navigation

None of this touches SwiftUI, so the whole navigation model tests without a
UI: parse a URL, call `open`, and assert on `peek` reads of tab, path, and
sheet ([Testing](./testing.md)).
