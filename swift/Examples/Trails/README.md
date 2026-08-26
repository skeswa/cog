# Cog Trails

Trails is a small hiking-guide app whose every navigation container — tab
selection, all four `NavigationStack` paths, and the modal sheet — is driven
by Cog graph state. It exists to show that full-app navigation, deep linking,
and state restoration need no router objects: navigation is ordinary state,
and the idioms are the same ones TodoMVC uses for todos.

Open `Trails.xcodeproj`, or build it from the repository:

```sh
mise run build:trails
```

## Try the deep links

The app registers the `cog-trails://` scheme. From Safari in the simulator, or
with `xcrun simctl openurl booted <url>`:

```text
cog-trails://saved
cog-trails://region/silver-coast
cog-trails://trail/mist-ridge
cog-trails://trail/painted-wash/log
cog-trails://search?q=falls
```

A trail link lands with its region already on the Explore stack beneath it, so
the back button works; the `/log` form also presents the hike logger. Every
row on the Journal tab shows the URL that reproduces its screen and reopens it
through the same code path.

## What it demonstrates

- `TrailNavigation+Cogs.swift` keeps the selected tab, each tab's route stack
  (a `CogBox` keyed by tab), and the presented sheet as separate manual
  sources. Pushing on one tab invalidates only that tab's path; presenting the
  sheet invalidates no path at all.
- A deep link resolves to **one atomic turn** that writes tab, stack, and
  sheet together. `cog-trails://trail/painted-wash/log` switches tabs,
  rebuilds a two-deep stack, and presents the logger with no observable
  halfway state. `TrailDeepLink` parsing and printing are pure inverses,
  testable without a graph.
- `currentScreenCog` derives the single topmost screen from the navigation
  sources. The journal mechanism watches it and records every transition —
  tap, gesture, URL, or restoration — with no per-screen tracking code. That
  is the analytics pattern with the service replaced by a visible log.
- `HikeTimerMechanism` hangs a `whenever` scope on the derived
  `isLoggingHikeCog`, so the elapsed-time ticker exists exactly while the
  logger sheet is up, however it was presented, and cancels on any dismissal.
- `TrailState+Bindings.swift` adapts graph state to `TabView`,
  `NavigationStack(path:)`, `sheet(item:)`, and `.searchable`. System-driven
  navigation — back gestures, interactive dismissal, `NavigationLink(value:)`
  pushes — writes back through the same named operations, and equal writes
  are discarded by the turn itself. Re-tapping the selected tab pops it to
  its root through the same setter.
- `trailSnapshotCog` aggregates tab, paths, sheet, bookmarks, and hike log
  from one settled turn; the persistence mechanism restores it during
  assembly, so the first rendered frame is the restored screen. Cold-launch
  URLs, warm navigation, and restoration are one code path because routes
  carry identities and screens resolve content from the immutable catalog.
- The navigation and domain state files keep their sources file-private and
  still compose atomic cross-feature operations — `logHike` appends an entry
  and dismisses the sheet in one turn by calling the other file's operation
  inside its turn body, where the nested turn joins.
- Keyed derived state stays fine-grained end to end: each trail row reads its
  own `isTrailSavedCogs` key, each detail screen its own `hikeCountCogs` key,
  and the Saved tab badge reads an equality-gated count.

The search query and journal are deliberately session-scoped; a relaunch
restores where you were, not what you were mid-typing. Stale identities in
old URLs degrade to a not-found screen instead of crashing.
