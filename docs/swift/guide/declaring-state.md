# Declaring state

_August 26, 2026_

A declaration is an immutable name and recipe; the runtime creates the mutable
state behind it on first use. This chapter covers how to name declarations,
which shape to pick, and the underscore-and-projection pattern that controls
who can write.

## Name by shape

Every keyless value reference ends in `Cog`; every keyed box ends in plural
`Cogs`. This includes manual, automatic, async, and read-only projection
declarations alike — the suffix says "this is a graph reference," not which
shape it is. Narrower qualifiers go before the suffix:

```swift
let temperatureCog: Cog<Int>                       // keyless value
let weatherForecastCogs: CogBox<WeatherReading?, ZipCode>  // keyed box
let weatherServiceLoaderCog: …                     // qualifier before suffix
```

The app runtime itself stays the ordinary local `cogs`, and values read from
the graph get normal domain names without either suffix
([Reading state](./reading-state.md)). The result is that a name tells you
which side of the graph boundary it lives on at a glance.

## Underscore the source; project the clean name

Every manual declaration begins with a leading underscore, whether or not it
is published. When the state is published, the `.readOnly` projection takes
exactly the source's name without the underscore, so the clean name is the one
the rest of the app reads:

```swift
/// The selected tab.
private let _selectedTabCog = Cog<TrailTab>.Manual { .explore }

/// Read-only selected tab.
let selectedTabCog = _selectedTabCog.readOnly
```

Why this shape:

- Only code in the declaring file can write `_selectedTabCog`, so the file
  boundary is the write boundary. Everything else — views, other clusters,
  mechanisms — reads the projection and mutates through the file's named
  operations ([Writing state](./writing-state.md)).
- The underscore makes a write site visually distinct: a `turn` body touching
  `_something` is touching a source.

Spell file-scope declarations `private`, not `fileprivate` — swift-format
rewrites file-scoped `fileprivate` to `private`. The retired `Source`
qualifier (`temperatureSourceCog`) must not reappear. `coglint`'s
`manual-cog-underscore` rule enforces both halves of this pattern.

## Initial values are closures

A manual starting value is a closure, not a bare value:
`Cog<Int>.Manual { 0 }`. Cog calls it once per state, so two runtimes, two
keys of a box, and a `whileObserved` state recreated after release never share
one object. This matters most for reference types and is free for value types,
so it is uniform.

## Choosing a shape

**Manual** (`Cog<T>.Manual`, `CogBox<T, K>.Manual`) — a fact something outside
the graph decides: a user choice, a navigation position, a received record.

**Automatic** (`Cog<T> { c in … }`, `CogBox<T, K> { c, key in … }`) — a fact
fully determined by other graph state. It is cached, recomputes only when a
dependency changes, and is equality-gated:

```swift
/// Number of bookmarks, equality-gated for the Saved tab badge.
let savedTrailCountCog = Cog<Int> { c in
  let savedTrailIDs = c[savedTrailIDsCog]
  return savedTrailIDs.count
}
```

Prefer a _keyed_ automatic box when consumers care about one slice each: every
Trails row reads `isTrailSavedCogs[trailID]`, so toggling one bookmark
invalidates one row, not the list.

If a value is genuinely derived, declare it automatic — never compute it
inline in several views, and never bundle several reads into a struct to
imitate one ([Reading state](./reading-state.md)).

**Async** (`Cog<T>.Async`, `CogBox<T, K>.Async`) — a fact that arrives from
outside the process. The declaration has a required `default:`, selects its
dependencies synchronously, and returns work that runs away from the
MainActor:

```swift
let weatherForecastCogs = CogBox<WeatherReading?, ZipCode>.Async(default: nil) { c, zip in
  let weatherService = c[weatherServiceCog]
  return .run { @concurrent in
    try await weatherService.forecast(for: zip)
  }
}
```

A normal read of an async value is total: it returns the last accepted success
or the default. Uncertainty stays explicit in `CogStatus`, read through the
opt-in `status` lens. `.latest` is the default concurrency policy; `.queue`
runs requests in order; `.exhaustLatest` finishes current work and catches up
once. The full model is [core design §4](../design/exploration.md).

**Projection** (`.readOnly`) — the published face of a manual source, as
above.

## Lifetime

Manual state and UI-observed state live for the app by default; unused
automatic and async state may expire after a grace period. A source that must
reset when nothing observes it opts in explicitly with
`lifetime: .whileObserved(resetToInitial: true)`. Reach for that only when
"nobody is looking" genuinely means "the fact is gone" — a draft, a live
connection — and rely on the defaults otherwise.

## Where declarations live

Declarations are file-scope `let`s in the cluster's `+Cogs.swift` file
([Structuring an app](./app-structure.md)), main-actor-isolated by the
target's MainActor default isolation. The value types they manage live in the
cluster's `+Model.swift`.
