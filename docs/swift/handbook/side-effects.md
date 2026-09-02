---
description: "Mechanisms, initial state in operate, the persistence pattern, and gated scopes."
---

# Side effects

Every app-wide side effect has one home: a `Mechanism`, registered at
assembly. Mechanisms live in the cluster's `+Mechanisms.swift` file, own
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

## Gated scopes: lifetime as state

Some work should exist only while some fact is true. Do not register and
cancel it by hand. Its lifetime _is_ a Bool cog, and `whenever` hangs a
scope on it:

```swift
struct HikeTimerMechanism: Mechanism {
  var clock: any Clock<Duration> = ContinuousClock()

  func operate(_ m: MechanismController) {
    m.whenever(isLoggingHikeCog, name: "hikeTimer") { s in
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

## Task closures are nonisolated

A `task` closure is nonisolated, so touching the graph goes through an
awaited op call — `await s.tickHikeTimer()` above. Inside a `whenever` body,
reads other than its own registrations use `peek` through the controller and
never re-trigger the scope. The gate stays the scope's only tracked
dependency.

## Where this is specified

The full mechanism model — the controller surface, ordering guarantees,
view-scoped effects, testing, and background execution — is
[mechanisms §6](../design/mechanisms.md).
