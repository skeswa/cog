---
description: "Mechanisms, initial state in operate, the persistence pattern, and gated scopes."
---

# Side effects

Every app-wide side effect has one home: a `Mechanism`, registered at
assembly. Mechanisms live in the rig's `+Mechanisms.swift` file, own
their capabilities as stored properties, and touch the graph only through
the controller they are handed.

## The mechanism shape

```swift
struct TrailJournalMechanism: Mechanism {
  func operate(_ m: MechanismController) {
    m.watch(currentScreenCog, initial: .run, name: "journal") { [weak m] _, screen in
      m?.recordScreenVisit(screen)
    }
  }
}
```

The conventions that keep mechanisms predictable:

- **Dependencies are stored properties, injected at assembly.** A capability
  the mechanism owns — a store, a notifier, a clock — arrives through its
  initializer. Production passes a `.live` value; tests pass a double:
  `TrailPersistenceMechanism(store: .live)`.
- **Name every registration.** Names compose under the mechanism name
  (`Trail.persistence`, `Weather.session.heartbeat`). They are what debug
  history and Instruments show.
- **Capture the controller weakly in anything long-lived.** A task or
  reaction holds `[weak m]` and stops when the scope is gone, so teardown
  never waits on cancelled code.
- **Inject clocks.** Timed work sleeps on a stored `any Clock<Duration>`
  that defaults to `ContinuousClock()`, so tests can substitute a controlled
  clock ([Testing](./testing.md)).

## Initial app state belongs in `operate`

`operate` runs inside assembly. Its writes finish before `assemble` returns,
so no watcher ever observes the pre-initial value on the way past. The app
entry point assembles and retains the runtime; it does not write to it.

```swift
func operate(_ m: MechanismController) {
  m.installTrailState(store.load() ?? Self.firstRun)   // settled before launch finishes

  m.watch(trailSnapshotCog, initial: .skip, name: "persistence") { _, snapshot in
    store.save(snapshot)
  }
}
```

A test sets up the same starting world by passing the same mechanism to
`Cogs.forTesting(mechanisms:)`. Note that `forTesting`'s `seeding:` closure
is not the production counterpart of this. Seeding installs values with no
turn, before anything watches — a testing need, nothing more.

## The persistence pattern

Both TodoMVC and Trails persist through the same three-part shape. Copy it:

1. **A snapshot cog** — one automatic value that gathers everything durable
   from one settled turn, so storage always sees a coherent document
   (`trailSnapshotCog`).
2. **A store capability** — a small struct with injected `load`/`save`
   closures and a `.live` value backed by UserDefaults or a file. Storage
   never becomes a second live source: it is read once during assembly, then
   only written.
3. **An install-then-watch mechanism** — `operate` installs
   `store.load() ?? firstRun` through a named op, then watches the snapshot
   cog with `initial: .skip` and saves each later value.

Restoration this way is invisible. The writes finish during assembly, so the
first rendered frame is already the restored screen — no flash of the
defaults. This pattern treats storage as a cache of graph state. Work whose
durable record must survive the process dying has stricter ordering rules;
see [mechanisms §6.7](../design/mechanisms.md).

## Scopes: lifetime as state

Some work should exist only while some fact is true. Do not register and
cancel it by hand. Its lifetime _is_ a cog, and `scope` hangs a child
controller on it. The simplest form reads a Bool:

```swift
struct HikeTimerMechanism: Mechanism {
  var clock: any Clock<Duration> = ContinuousClock()

  func operate(_ m: MechanismController) {
    m.scope(isLoggingHikeCog, name: "hikeTimer") { s in
      s.resetHikeTimer()
      s.task(name: "tick") { [weak s] in
        while true {
          try await clock.sleep(for: .seconds(1))
          guard let s else { return }
          await s.tickHikeTimer()
        }
      }
    }
  }
}
```

The gate is the scope's only tracked dependency. When the gate falls,
everything registered through the sub-controller ends: reactions unregister
and tasks cancel. The next rise runs the body again from scratch. Nothing
survives a down-and-up cycle — each presentation of Trails' logger restarts
its clock from zero. Anything that must survive belongs in graph state, not
in the scope.

Note that the gate here is derived. `isLoggingHikeCog` is computed from
navigation state, so the timer's lifetime follows the sheet _however_ it was
presented or dismissed — button, gesture, deep link, or restoration.

## When the lifetime has a name, select its identity

The two sketches below are not from the example apps. Trails' navigation stack
holds routes rather than per-opening identities, and none of the three examples
has a session, so these show the shape rather than pointing at code you can
open.

A Bool says whether work should exist. It cannot say _which_ lifetime owns it,
and some work needs to know. A session ends and another begins while onboarding
stays active; a user signs the same account in twice; a screen is dismissed and
reopened for the same trail. In each case the gate never falls, so a gated scope
keeps running against a lifetime that is over.

Select an optional identity instead, and the body receives the exact identity
that opened it:

```swift
m.scope(activeSessionCog, name: "session") { session, s in
  // Bound once, to this session. A completion cannot pick up the next
  // session's credentials after a suspension.
  let credentials = credentials.bound(to: session)

  s.watch(pendingUploadsCog, initial: .run, name: "sync") { _, uploads in
    sync.enqueue(uploads, using: credentials)
  }
}
```

`nil` means no lifetime, so no child. A different identity retires the old child
— unregistering its watches, cancelling its tasks — and opens a new one, in one
turn, with no invented gap in between. An _equal_ identity is the same lifetime
and changes nothing, so a source that republishes an equal value never restarts
the work.

The rule that makes this work is about where identity comes from: **mint it in
the op that creates the lifetime.** Signing in mints an epoch; refreshing a
token does not. Opening a screen mints a presentation ID; typing in its search
field does not. An identity minted inside a selector would make every
recomputation a new lifetime, tearing down and rebuilding work on every
keystroke.

## Many lifetimes at once

A navigation stack has one lifetime per entry, and entries come and go in any
order. `scope(each:)` reconciles them from a collection of stable IDs:

```swift
m.scope(each: openTrailScreensCog, name: "trailScreen") { screenID, s in
  s.watch(trailFilterCogs[screenID], initial: .skip, name: "filter") { _, filter in
    analytics.record(.filterChanged(filter), screen: screenID)
  }
}
```

An ID that arrives opens a child. An ID that stays keeps its exact child, its
registrations, and its running tasks — including when the collection is
reordered, or when a sibling is added or removed. An ID that leaves retires its
child. Two entries showing the same trail have different IDs, so they own
separate work and neither can end the other's.

This is one registration, not one per entry. That matters: registering a
selector per pushed entry would leave a dormant watch behind for every screen
the app has ever shown.

## Retirement makes a scope inert, not merely cancelled

Cancellation is a request. An HTTP call already sent will finish anyway, and a
`[weak s]` capture that was promoted before an `await` is still valid after it.
So Cog revokes a retired scope's access instead of relying on those:

- `turn` and every op built on it do nothing, including a turn that was already
  waiting in the queue when the scope was retired.
- `run`, `watch`, `status.watch`, and `scope` register nothing — not even the
  initial callback.
- `task` returns an already-cancelled task whose body never starts.
- `peek`, `status.peek`, and `refresh` trap. They cannot invent a value, and a
  refresh that answered "released" would be claiming the shared state left the
  graph, which one ended screen does not know.

The practical consequence is that a completion should **publish through a
receipt-bearing op** rather than checking anything first:

```swift
s.task(name: "load") { [weak s] in
  let trail = try await service.load(trailID)
  await MainActor.run { s?.acceptTrail(trail, receipt: screenID) }
}

// TrailRig+Cogs.swift
extension CogOps {
  func acceptTrail(_ trail: Trail, receipt: TrailScreenID) {
    turn { c in
      guard c[_openTrailScreensCog].contains(receipt) else { return }
      c[_loadedTrailCogs[receipt]] = trail
    }
  }
}
```

Both checks live inside the writer body. A retired scope never gets there, and a
live one still has to prove the screen it loaded for is the screen that is open.

When a completion really has to read — to decide whether to retry, or to ask for
more — wrap that read:

```swift
guard let s, s.ifLive({ $0.peek(isRefreshableCog) }) == true else { return }
```

`ifLive` checks once, when it is called. It is not a reservation: if something
inside its body retires the scope, the statements after that are running through
a retired controller like any others. Re-check after every `await`.

Note what retirement does _not_ do. It ends registrations and asks tasks to
stop. It writes nothing, resets nothing, and reclaims no state. That is a
deliberate split, not an omission: releasing a departed screen's values is the
job of the op that closed the screen, through `discard`
([Writing state](./writing-state.md)). Shared trail data stays owned by whoever
else is reading it either way.

## Task closures are nonisolated

A `task` closure is nonisolated, so touching the graph goes through an
awaited op call — `await s.tickHikeTimer()` above. Inside a `scope` body,
reads other than its own registrations use `peek` through the controller and
never re-trigger the scope. The selected state stays the scope's only tracked
dependency.

## Where this is specified

The full mechanism model — the controller surface, ordering guarantees,
view-scoped effects, testing, and background execution — is
[mechanisms §6](../design/mechanisms.md).
