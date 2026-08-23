# Cog for Swift: Rx operator map

_August 6, 2026_

This file is §5.4 of [core design](./exploration.md).

### 5.4 Where the Rx operators went

A cog holds current state. A stream carries events. Cog keeps those jobs
separate instead of copying Rx operators into the graph.

#### Dynamic reads switch state

An automatic cog depends on what it reads during each run:

```swift
let weatherHereCog = Cog { c in
    guard let currentZip = c[currentZipCog] else { return nil as Weather? }
    let weatherReport = c[weatherReportCogs[currentZip]]
    return weatherReport
}
```

When the ZIP changes, the next run drops the old weather edge and adds the new
one. This is the state form of `switchMap`. The same rule follows a changing
list:

```swift
let shouldPackHatCog = Cog { c in
    let vacationZipCodes = c[vacationZipCodesCog]
    return vacationZipCodes.contains { zip in
        let shouldWearHat = c[shouldWearHatCogs[zip]]
        return shouldWearHat
    }
}
```

Removed ZIPs lose their edges because every run must read its dependencies
again.

#### Async policies switch work

The policy in §5.2 controls old and new work:

- `.latest` cancels old work and starts new work: `switchMap`.
- `.queue` runs work in order: `concatMap`.
- `.merged` allows overlap: `flatMap` or `merge`.
- `.exhaustLatest` finishes current work, then runs once with the newest state.

True event dropping belongs in an op. A state value must catch up after a
dependency changes.

```swift
let forecastCog = Cog<Forecast?>.Async(.latest) { c in
    let currentZip = c[currentZipCog]
    return .run { try await api.forecast(for: currentZip) }
}
```

#### `.stream` follows a real stream

Use `.stream` for sources such as location updates, sockets, and database
observations:

```swift
let locationFixCog = Cog<CLLocation?>.Async(.latest) { c in
    let desiredAccuracy = c[desiredAccuracyCog]
    return .stream(locationService.updates(accuracy: desiredAccuracy))
}
```

Each changed element publishes in its own turn. Equal `Equatable` elements do
nothing. A dependency change cancels the old sequence and starts a new one.
Streams use `.latest` only because other policies can wait forever for a stream
to end.

#### Operator dictionary

| Rx operator            | Cog form                                                                                          |
| ---------------------- | ------------------------------------------------------------------------------------------------- |
| `map`, `combineLatest` | An automatic cog with one or more tracked reads                                                   |
| `withLatestFrom`       | `c.peek(...)`, which reads without adding an edge                                                 |
| `switchMap`            | Dynamic reads, `.latest`, or `.stream`                                                            |
| `concatMap`, `flatMap` | `.queue`, `.merged`                                                                               |
| `exhaustMap`           | `.exhaustLatest` for state; an op for true event dropping                                         |
| `distinctUntilChanged` | Cog's state equality checks                                                                       |
| `scan`                 | `c.curr`, the cog's prior value                                                                   |
| `debounce`, `throttle` | Future timing options at the edge; these are not part of the graph and are still open in core §10 |

A cog does not store ordered event history. Keep tap and duplicate-event
pipelines in ops, reactions, and `AsyncSequence`. A cog read always means “the
current value.”

#### Prior art

Per-run reads replace the old Conveyor `temporarily: true` edge flag. `.stream`
matches Atoms' `AsyncSequenceAtom` and the `flatMapLatest` work in
swift-async-algorithms. Atoms also places timing options at the edge.
