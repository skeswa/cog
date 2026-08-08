# Cog for Swift: Rx operator map

_August 6, 2026_

This appendix is §5.4 of [exploration.md](./exploration.md). It explains how
stream operators map to Cog. Other section numbers point to the core file.

### 5.4 Where the Rx operators went

Signals hold current state. Streams carry events over time. Because these are
different jobs, Cog does not copy Rx operators into its state graph. Their
behavior comes from three smaller tools.

#### 1. Dynamic dependencies switch state

A derived cog depends on what it read during its last run:

```swift
let weatherHere = Cog { c in
    guard let zip = c.get(currentZipCode) else { return nil as Weather? }
    return c.get(weatherReport[zip])
}
```

If the ZIP changes, the next run drops the old weather edge and adds the new
one. This is the state part of `switchMap`. The same rule can flatten a cog of
cogs or follow a changing set:

```swift
let shouldPackHat = Cog { c in
    c.get(vacationZipCodes).contains { zip in
        c.get(shouldWearHat[zip])
    }
}
```

This run depends only on the current ZIP list and its current hat cogs. Every
dependency must be read again on each run, so removed ZIPs lose their edges.

#### 2. Async policies switch work

When dependencies choose async work, the policy in §5.2 controls old and new
runs:

- `.latest` cancels old work and starts new work. This is `switchMap`.
- `.queue` runs work in order. This is `concatMap`.
- `.merged` allows overlap. This is `flatMap` or `merge`.
- `.exhaustLatest` finishes the active run, then catches up once with the
  newest state.

A derived value cannot forget state changes forever and remain correct. True
drop or exhaust behavior therefore belongs to imperative ops, whose inputs
are events.

```swift
let forecast = AsyncCog<Forecast>(.latest) { c in
    let zip = c.get(currentZipCode)
    return .run { try await api.forecast(for: zip) }
}
```

Here the selector follows the new ZIP, while `.latest` cancels the old fetch.

#### 3. `.stream` follows real streams

Some sources really are streams, such as location updates, websockets, and
database observations:

```swift
let locationFix = AsyncCog<CLLocation>(.latest) { c in
    let accuracy = c.get(desiredAccuracy)
    return .stream(locationService.updates(accuracy: accuracy))
}
```

Cog commits each sequence element as its own turn. If `accuracy` changes, Cog
cancels the old sequence and starts the new one. This is `flatMapLatest` at a
graph node. A stream may use only `.latest`; other policies have no safe v1
meaning for work that may never end.

#### Operator dictionary

| Rx operator            | Cog equivalent                                                                         |
| ---------------------- | -------------------------------------------------------------------------------------- |
| `map`, `combineLatest` | A derived cog. Multiple `c.get` calls combine current values.                          |
| `withLatestFrom`       | `c.read(...)`: read the current value without tracking it.                             |
| `switchMap`            | Dynamic dependencies, `.latest`, or `.stream`, depending on what switches.             |
| `concatMap`, `flatMap` | `.queue`, `.merged` (§5.2).                                                            |
| `exhaustMap`           | `.exhaustLatest` for state; true exhaust on imperative ops.                            |
| `distinctUntilChanged` | Equality checks built into every node (§2.4).                                          |
| `scan`                 | `c.curr`, which exposes the cog's prior value.                                         |
| `debounce`, `throttle` | Timing options at the edge: a reaction modifier or async-cog option, not graph basics. |

Cog does not replace streams of ordered event history. A cog holds the current
value, not every tap or duplicate event. Keep those pipelines in ops and
reactions, backed by `AsyncSequence` and tools such as `share()`. This boundary
keeps a state read unambiguous: it means “the current value,” not “the next
event.”

#### Notes and prior art

The 2023 Conveyor drafts marked dynamic links as `temporarily: true`. Per-run
dependency capture makes that flag needless: every edge must be earned again.
Cog-of-cog flattening and the old vacation example use the same rule.

`.stream` matches Atoms' `AsyncSequenceAtom` and the `flatMapLatest` work in
swift-async-algorithms. Timing modifiers also follow Atoms' useful precedent:
they are optional edge features, not core state semantics.
