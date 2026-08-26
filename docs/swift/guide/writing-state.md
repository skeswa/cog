# Writing state

_August 26, 2026_

`turn` is the only write primitive, and application code never calls it
inline. Every mutation goes through a named domain operation, and every
operation publishes exactly one atomic turn — those two rules are most of this
chapter; the rest is what they compose into.

## Wrap every primitive in a named op

`turn` and `refresh` are how the graph is asked to do something, not what an
app calls the asking. Application code — a view action, a button, a mechanism
— calls a domain verb from a `CogOps` extension, never the primitive inline:

```swift
extension CogOps {
  /// Replaces the search text with the field's latest value.
  func setSearchQuery(_ query: String) {
    turn(_searchQueryCog, to: query)
  }

  /// Demands a fresh forecast for one ZIP.
  func refreshForecast(for zip: ZipCode) {
    refresh(weatherForecastCogs[zip])
  }
}
```

The rule applies to `refresh` for the same reason it applies to `turn`: both
are demands on the graph, and neither is domain vocabulary. Keeping the
primitive inside the state layer means the declaration a call site resolves to
lives with the rest of that cluster — a reader of `cogs.refreshForecast(for:)`
finds the async declaration, its service dependency, and the op in one file.

Because ops extend `CogOps`, one definition serves every caller: views call
ops on `cogs`, a mechanism calls the same ops on its controller `m`, and a
gated scope on its sub-controller `s`.

## One op, one turn

One outer `turn` call is one graph turn: every source staged inside the body
publishes together, and no observer can see a halfway state. Reach for the
block form whenever a domain action touches more than one fact:

```swift
/// Jumps to one trail on the Explore tab from anywhere in the app.
func showTrailInExplore(_ trailID: TrailID) {
  guard let trail = TrailCatalog.trail(trailID) else { return }
  turn { c in
    c[_selectedTabCog] = .explore
    c[_tabPathCogs[TrailTab.explore]] = [.region(trail.regionID), .trail(trailID)]
    c[_presentedSheetCog] = nil
  }
}
```

Inside the body, the `Writer` sees that turn's staged values — a later line
reading `c[_tabPathCogs[…]]` sees what an earlier line wrote. Writes of equal
values are discarded by the turn itself, which is what makes redundant
system-driven binding writes free ([SwiftUI integration](./swiftui.md)).

Two things a turn body must not do: read-modify-write across an `await` (a
turn is synchronous), and write from inside an automatic computation — the
runtime rejects that with a clear error.

## Compose across files with nested turns

A nested `turn` joins the outer turn. This is the idiom that lets each
cluster keep its sources file-private and still take part in atomic
cross-cluster actions: an op calls the _other file's op_ inside its turn
body, and both publish as one turn.

```swift
/// Commits a hike entry and dismisses the logger in one settled turn.
func logHike(for trailID: TrailID, note: String, …) {
  turn { c in
    c[_hikeEntriesCog] = [entry] + c[_hikeEntriesCog]
    self.dismissSheet()   // nested turn joins; entry and dismissal publish together
  }
}
```

Trails uses the same idiom for restoration (`installTrailState` calls
`installNavigation`) and for deep links (`open(.search)` calls
`setSearchQuery`). The composed op never needs access to the other cluster's
sources — only to its public operation — so the write boundary established by
file privacy survives composition.

## Reaction writes are later turns

A write from a reaction — a mechanism's `watch` handler calling an op — does
not join the turn it observed. It waits in a FIFO queue and becomes its own
turn after the current flush. That is the correct mental model for anything
event-shaped: the journal entry recording a navigation lands one turn after
the navigation itself.

If mechanisms form a turn → reaction → turn loop, a debug guard warns after
about 64 turns and prints the named cause chain.

## Where this is specified

Turn semantics and the write model are
[core design §3](../design/exploration.md); reaction ordering is
[mechanisms §6.4](../design/mechanisms.md).
