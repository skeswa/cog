# Side effects

_August 26, 2026_

Every app-wide side effect has one home: a `Mechanism`, registered at
assembly. Mechanisms live in the cluster's `+Mechanisms.swift` file, own their
capabilities as stored properties, and touch the graph only through the
controller they are handed.

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
  initializer, with a `.live` production value and a test double in tests:
  `TrailPersistenceMechanism(store: .live)`.
- **Name every registration.** Names compose under the mechanism name
  (`Trail.persistence`, `Weather.session.heartbeat`) and are what debug
  history and Instruments show.
- **Capture the controller weakly in anything long-lived.** A task or
  reaction holds `[weak m]` and stops when the scope is gone, so teardown
  never waits on cancelled code.
- **Inject clocks.** Timed work sleeps on a stored `any Clock<Duration>`,
  defaulting to `ContinuousClock()`, so tests substitute a controlled clock
  ([Testing](./testing.md)).

## Initial app state belongs in `operate`

`operate` runs inside assembly, so its writes settle before `assemble`
returns and no watcher observes the pre-initial value on the way past. The
app entry point assembles and retains the runtime; it does not write to it.

```swift
func operate(_ m: MechanismController) {
  m.installTrailState(store.load() ?? Self.firstRun)   // settled before launch finishes

  m.watch(trailSnapshotCog, initial: .skip, name: "persistence") { _, snapshot in
    store.save(snapshot)
  }
}
```

A test arranges the same starting world by passing the same mechanism to
`Cogs.forTesting(mechanisms:)`. `forTesting`'s `seeding:` closure is not the
production counterpart of this — it installs values without a turn, before
anything watches, which is a testing need.

## The persistence pattern

Both TodoMVC and Trails persist through the same triad, and it is the shape to
copy:

1. **A snapshot cog** — one automatic value aggregating everything durable
   from one settled turn, so storage always sees a coherent document
   (`trailSnapshotCog`).
2. **A store capability** — a small struct with injected `load`/`save`
   closures and a `.live` UserDefaults- or file-backed value. Storage never
   becomes a second live source: it is read once during assembly, then only
   written.
3. **An install-then-watch mechanism** — `operate` installs
   `store.load() ?? firstRun` through a named op, then watches the snapshot
   cog with `initial: .skip` and saves each later value.

Restoration this way is invisible: the writes settle during assembly, so the
first rendered frame is already the restored screen, with no flash of resting
defaults. This pattern treats storage as a cache of graph state; work whose
durable record must survive process death has stricter ordering rules —
see [mechanisms §6.7](../design/mechanisms.md).

## Gated scopes: lifetime as state

Work that should exist only while some fact is true does not get registered
and cancelled imperatively — its lifetime _is_ a Bool cog, and `whenever`
hangs a scope on it:

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

The gate is the scope's only tracked dependency. When it falls, everything
registered through the sub-controller ends — reactions unregister, tasks
cancel — and the next rise runs the body again from scratch. Nothing survives
a down-and-up cycle, so each presentation of Trails' logger restarts its clock
from zero; continuity that must survive belongs in graph state, not in the
scope.

Note the derived gate: `isLoggingHikeCog` is computed from navigation state,
so the timer's lifetime follows the sheet _however_ it was presented or
dismissed — button, gesture, deep link, or restoration.

## Task closures are nonisolated

A `task` closure is nonisolated, so touching the graph goes through an
awaited op call — `await s.tickHikeTimer()` above. Reads inside a `whenever`
body other than its own registrations use `peek` through the controller and
never re-trigger the scope; the gate stays the scope's only tracked
dependency.

## Where this is specified

The full mechanism model — the controller surface, ordering guarantees,
view-scoped effects, testing, and background execution — is
[mechanisms §6](../design/mechanisms.md).
