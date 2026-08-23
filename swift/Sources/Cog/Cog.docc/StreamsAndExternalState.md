# Streams and external state

Bring an asynchronous sequence into Cog, export a Cog value to asynchronous
code, or make an external observable property a graph dependency.

## Overview

Cog has one authoritative graph, but not every producer or consumer begins
inside that graph. Use a boundary that states the direction of travel:

- ``Work/stream(_:)`` lets an async declaration own an `AsyncSequence` and
  publish its elements as Cog turns.
- ``Cogs/values(of:buffering:)-(Cog<Value>,_)`` lets asynchronous code consume
  a Cog value without creating another state owner.
- ``Reader/track(_:_:)`` makes an external `@Observable` property an ordinary
  selector dependency.

Each boundary keeps Cog's turn, cancellation, equality, and lifetime rules. It
does not mirror mutable state into a second graph.

### Select stream work

Return ``Work/stream(_:)`` from a latest-policy async declaration when one
request produces several values:

```swift
let temperatureCog = Cog<Int>.Async(
  default: 0,
  name: "temperature"
) { _ in
  .stream(weatherService.temperatures)
}
```

The first read starts iteration and returns the declared default while status
is pending. Each changed element becomes its own completed Cog turn. Replacing
the declaration's dependencies or releasing its state cancels the iterator and
rejects any late element. Natural sequence completion publishes no extra
status: the last accepted success remains current, while a sequence that ended
empty remains pending until refresh or dependency change selects new work.

Streams deliberately use ``LatestPolicy`` only. For one-shot work that must not
replace its active request, select an ``OrderedPolicy`` and return
``RunWork/run(_:)``:

```swift
let searchCog = Cog<[SearchResult]>.Async(
  .queue,
  default: [],
  name: "search"
) { c in
  let query = c[queryCog]
  return .run { try await client.search(query) }
}
```

`.queue` drains every selection in FIFO order, `.exhaustLatest` keeps one
newest catch-up while busy, and `.merged` lets runs overlap. ``RunWork`` has no
stream factory, so Swift rejects an ordered stream declaration before a graph
exists.

### Export a Cog value

Use `values(of:)` when a task or adapter needs changed values over time. The
sequence starts with the current settled value and never makes a synchronous
Cog turn wait for its consumer:

```swift
struct ForecastReporter: View {
  @Environment(\.cogs) private var cogs

  var body: some View {
    Color.clear
      .task {
        for await forecast in cogs.values(of: forecastCog) {
          await reporter.accept(forecast)
        }
      }
  }
}
```

Every iterator owns an independent subscription and graph lease. Cancelling
the task or releasing the iterator removes its dependency edges and lifetime
claim. The default ``CogValuesBuffering/newest(_:)`` policy is `.newest(1)`,
which bounds memory and lets a slow reader catch up to current state. Choose
``CogValuesBuffering/oldest(_:)`` for the earliest bounded backlog or
``CogValuesBuffering/unbounded`` only when lossless delivery justifies
unbounded memory.

An async declaration exports its total value projection, not every
``CogStatus`` transition. Pending or failure alone emits nothing; a later
accepted value emits when the declaration's equality rule says it changed.

### Track an external observable value

Use ``Reader/track(_:_:)`` inside a selector when an external `@Observable`
model remains the owner of a fact:

```swift
import Observation

@MainActor
@Observable
final class Profile {
  var givenName = ""
  var familyName = ""
}

let displayNameCog = Cog<String> { c in
  c.track(profile) { profile in
    "\(profile.givenName) \(profile.familyName)"
  }
}
```

For one property, prefer the key-path form:

```swift
let givenNameCog = Cog<String> { c in
  c.track(profile, \.givenName)
}
```

Cog gives the selector an ordinary hidden source edge; a sibling property that
was not read does not invalidate it. On iOS 26, macOS 26, and peer 26-era
runtimes, continuous Observation may coalesce mutations until an actor
suspension boundary. On older deployment targets, Cog re-arms
`withObservationTracking` after each callback and then reads the post-setter
value. That one-shot API necessarily has a small disarmed window: a mutation
made before re-arm completes may be missed.

Keep the model and tracked read on the MainActor. The tracked value need not be
`Sendable`, because Cog reads and publishes it without crossing isolation.

## See Also

- ``Cog/Async``
- ``Work``
- ``RunWork``
- ``OrderedPolicy``
- ``CogValues``
- ``CogValuesBuffering``
- ``Reader``
