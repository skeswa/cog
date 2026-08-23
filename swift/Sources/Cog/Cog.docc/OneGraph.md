# One graph, and how to test it

Why an app has exactly one ``Cogs``, and what that means for tests and
previews.

## Overview

Cog's fourth principle is that state is singular: one running app has one
authoritative graph, and each mutable fact has exactly one writable source in
it. Everything about the runtime follows from that, including the parts that
look inconvenient at first.

A second graph is not a second copy of your state. It is a second answer to the
same question, and nothing will tell you which one a given view is reading. The
bug shows up later, as a screen that will not update, or two screens that
disagree, and it is nearly unfixable by inspection because both graphs are
behaving correctly.

### The one-context rule

- **Assemble once, at launch.** ``Cogs/assemble(mechanisms:)`` creates the
  app's graph, runs every mechanism, and returns the object your app retains.
- **A second assembly traps**, in debug and release alike. It is not a
  warning: continuing would give the process two graphs.
- **There is no ambient lookup.** No `Cogs.app`, no shared singleton to reach
  for. The context travels through the SwiftUI environment, installed once at
  the composition root with `.cogEnvironment(cogs)`.
- **Features cannot construct one.** `Cogs` has no public initializer. The only
  ways to get one are assembly and the testing factory.
- **Views resolve it themselves.** Every view that touches Cog declares
  `@Environment(\.cogs) private var cogs`. A view never accepts, stores, or
  forwards a `Cogs` through its initializer; intermediate views pass domain
  values and identities. A view given a context by its parent is one refactor
  away from being given the wrong one.

A rebuilt scene receives the existing context. Scene reconstruction is not app
launch, and manual state survives it — that is the whole point of state living
in the graph rather than in view objects.

### Tests and previews are separate runtimes

The rule is one graph per *running app*, not one graph per process. A test and
a preview are each their own app runtime, so each may create exactly one
isolated context:

```swift
import Cog
import CogTesting
import Testing

@MainActor
@Test func advice() {
  let cogs = Cogs.forTesting()

  #expect(cogs.peek(adviceCog) == "coat")
  cogs.turn(_temperatureCog, to: 80)
  #expect(cogs.peek(adviceCog) == "shorts")
}
```

`Cogs.forTesting(clock:whileObservedGrace:seeding:mechanisms:)` starts empty
and isolated. It never occupies the production install slot, so a test can
never collide with an app assembly or with another test, and it needs no
teardown, reset, or `uninstall`. Contexts from two tests share nothing.

What still holds inside one test is the same singularity rule: create one
context and use it everywhere in that test. Creating a second one partway
through splits the state under test, which is the very bug the rule exists to
prevent — now inside your test instead of your app.

To host a view hierarchy, install the same way production does:

```swift
let cogs = Cogs.forTesting()
let view = Dashboard().cogEnvironment(cogs)
```

Previews work identically. Each preview creates its own context, so previews
neither share values with one another nor disturb the app.

### Arranging state before anything watches

`seeding:` runs before any mechanism's `operate`, which makes it the place to
arrange the world a mechanism will wake up into:

```swift
let cogs = Cogs.forTesting(
  seeding: { c in c.seed(_weatherServiceCog, to: .stubbed) },
  mechanisms: [WeatherMechanism(notifier: .capturing)]
)
```

`seed(_:to:)` is a debug-only setup tool, and deliberately not a write. It
installs a value and marks dependents dirty, but opens no turn, records no
history, and wakes no reaction — so seeding cannot be mistaken for the change
under test. It exists only in debug builds; a release build has no way to seed
at all.

For a change that *should* behave like a change, use ``Cogs/turn(_:to:name:)``
in the body of the test.

### Testing time without waiting

Anything Cog schedules — `whileObserved` grace, a mechanism's periodic loop —
runs on the context's clock. Inject `CogTesting.TestClock` and drive it:

```swift
let clock = TestClock()
let cogs = Cogs.forTesting(clock: clock, whileObservedGrace: .seconds(10))

try await clock.waitForScheduledSleep()
clock.advance(by: .seconds(10))
```

`waitForScheduledSleep()` returns when something has actually scheduled a
sleep, so `advance(by:)` moves past a deadline that exists rather than racing
one that has not been set yet. No lifetime or scheduling test waits wall-clock
time, and none polls.

### Testing production assembly

Occasionally the thing under test *is* the app install. `CogTesting` vends a
synchronous scope for it, so no test leaks a global install into the next one:

```swift
CogTesting.withAssembledCogs(mechanisms: [WeatherMechanism(notifier: .live)]) { cogs in
  #expect(CogTesting.isAssembledCogs(cogs))
}
```

The body is synchronous on purpose: no other MainActor work can observe the
temporary install, and it is uninstalled before the call returns even if the
body throws.

### If you are arriving from swift-state-graph

The read mapping is the one that trips people. There, a read inside a
computation is tracked through ambient state and you opt out with a
`withoutTracking { }` scope. In Cog the reader is a value you were handed, and
the opt-out is per read:

| swift-state-graph                | Cog                                |
| -------------------------------- | ---------------------------------- |
| read a node inside a computation | `c[someCog]`                       |
| `withoutTracking { node.value }` | `c.peek(someCog)`                   |
| read from a view                 | `cogs[someCog]`                    |
| read once, outside anything      | `cogs.peek(someCog)`               |

Capture lists in swift-state-graph's examples are ordinary Swift closure
capture, not dependency declarations; both libraries capture dependencies
dynamically from the reads a run actually performs.

## See Also

- <doc:GettingStarted>
- ``Cogs``
