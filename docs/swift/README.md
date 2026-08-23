# Cog for Swift

Cog is a state library for SwiftUI. It updates only the values and views that
depend on changed state. SwiftUI sees normal `@Observable` values. Cog keeps the
state graph on the MainActor.

This page is the map for the Swift docs. The design files share section
numbers, so a link such as §6.4 may point to another file.

## Start here

The [shared state model](../design.md) defines the rules Swift and Kotlin share.
For Swift, one `Cogs` object owns the app's state. Reads settle through its
graph, async status uses `CogStatus`, and Observation exists only at the UI
edge.

Read the Swift docs in this order:

1. **[Core design](./design/exploration.md)** — graph behavior, public API,
   writes, async state, SwiftUI, decisions, and open questions.
2. **[Mechanisms](./design/mechanisms.md)** — side effects, timers, gated work,
   bootstrap, tests, and background work.
3. **[Rx map](./design/rx.md)** — how Rx operators map to Cog.
4. **[Runtime design](./design/perf.md)** — storage, propagation, cost rules,
   and the measurement plan.
5. **[Prior-art review](./design/prior-art.md)** — the API review against
   swift-state-graph.
6. **[Lint design](./design/lint.md)** — the linter, plugins, rules, and
   distribution model.
7. **[Implementation plan](./impl/plan.md)** — package layout, milestones, CI,
   and releases.
8. **[Test scenarios](./impl/scenarios.md)** — every promised behavior as a
   test story.
9. **[Task graph](./impl/tasks.md)** — small tasks, dependencies, and closing
   checks.
10. **[Benchmark results](./impl/benchmarks.md)** — measurements, environments,
    decisions, and withdrawn results.
11. **[Optimization record](./impl/optimization.md)** — profiles, probes, and
    the result of each speed change.
12. **[Design history](../history.md)** — optional background from the earlier
    Dart and Flutter work.

This order also appears in `docs/.vitepress/navigation.mts`. Update both lists
when adding a document.

## Build and test

The git root is the SwiftPM package root. Swift targets live under `swift/`.
Use mise tasks instead of calling test tools directly:

```sh
mise run fmt                       # format docs, data files, and Swift
mise run fmt:check                 # check formatting without writing
mise run test                      # default test setup
mise run test:matrix               # all four isolation setups
mise run test:arena-configurations # default and CompactArena behavior
mise run test:release              # release build tests
mise run test:compilefail          # expected compiler errors
mise run test:storefront           # Storefront workload tests
mise run tasks:check               # check plan, tasks, and scenarios
```

Do not run a filtered `swift test` command. SwiftPM exits successfully when a
filter finds no tests. Cog's wrapper first checks that the tests exist, then
checks how many ran:

```sh
mise run test --filter 'DECL-01|ONE-05'
```

The test matrix combines MainActor or nonisolated defaults with
`NonisolatedNonsendingByDefault` on or off. A full Xcode is required. The
Command Line Tools fail to load Swift Testing. See the
[CI runbook](../maintainers/ci.md) for pinned versions and runners.

## Create the app runtime

Production code depends on `Cog`. At launch, call
`Cogs.bootstrapApp(mechanisms:)` once and keep its result for the life of the
app. Bootstrap starts every mechanism before it returns.

Install that same object above every SwiftUI scene:

```swift
import Cog
import SwiftUI

@main
@MainActor
struct WeatherApp: App {
  private let cogs: Cogs

  init() {
    cogs = Cogs.bootstrapApp(mechanisms: [
      WeatherMechanism(notifier: .live),
    ])
  }

  var body: some Scene {
    WindowGroup {
      RootScene()
        .cogEnvironment(cogs)
    }
  }
}
```

Each view that uses Cog reads `@Environment(\.cogs) private var cogs`. A view
must not accept, store, or pass `Cogs`. Pass normal values and IDs instead.

There is no global `Cogs.app`. Features cannot create a production runtime.
The app owns the one object returned by bootstrap.

## Create test and preview runtimes

Tests and preview-support targets depend on `CogTesting`. Each test or preview
creates one isolated runtime:

```swift
import Cog
import CogTesting
import Testing

@MainActor
@Test func counterStartsClean() {
  let countCog = ManualCog<Int>(0)
  let cogs = Cogs.forTesting()

  #expect(cogs.peek(countCog) == 0)
  cogs.turn { c in c[countCog] = 1 }
  #expect(cogs.peek(countCog) == 1)
}
```

`Cogs.forTesting(seeding:mechanisms:)` seeds state before it starts mechanisms.
Use the result directly in non-view tests or install it above a test view with
`.cogEnvironment(cogs)`. Do not create a second runtime inside the same test or
preview tree.

Use `TestClock` for timed tests. Pass it to code that schedules work and to
`Cogs.forTesting(clock:)` when testing Cog's lifetime grace period.

Only tests of production installation should use `withBootstrappedApp`:

```swift
@MainActor
@Test func appBootstrapIsTheSubject() {
  Cogs.withBootstrappedApp { cogs in
    #expect(Cogs.isBootstrappedApp(cogs))
  }
}
```

Its closure is synchronous and cannot nest. Do not use it as normal test setup.

## Current design

These rules are settled. The linked design files hold the full details.

### State and writes

- One app has one MainActor `Cogs` graph.
- `Cog<T>` and `ManualCog<T>` name one value. A `CogBox` makes keyed values
  from one declaration.
- Keyless declaration names end in `Cog`; box names end in `Cogs`. Values read
  from the graph use normal domain names without either suffix.
- `turn` is the only write primitive. App code wraps `turn` and `refresh` in
  named methods on `CogOps`.
- One outer `turn` call is one graph turn. Reaction writes wait in a FIFO queue
  as later turns.
- Cog settles each changed path with a live reader before it notifies the UI.
  Unused paths stay lazy.
- Tracked reads use subscripts. One-time reads use `peek`; they still settle
  the value but add no dependency.
- Dynamic cycles and writes during automatic computation fail with a clear
  error.

### Async state

- An async declaration has a required default value. A normal read returns the
  latest accepted value or that default.
- The `status` lens exposes `kind`, `value`, `hasSucceeded`, `error`, and
  `isLoading`. SwiftUI tracks only the fields it reads.
- `.latest` is the default policy. `.queue` runs requests in order.
  `.exhaustLatest` finishes current work and then catches up once. Streams use
  `.latest` only.
- Starting an unread async value creates one pending run. Release cancels work
  and rejects late results.
- Exported streams start with the current settled value. Their buffer policy
  controls what a slow reader may miss.

### Effects and lifetime

- A `Mechanism` owns app-wide side effects. Bootstrap starts mechanisms in
  array order through a limited `MechanismController`.
- A state-gated `whenever` scope owns shorter work. SwiftUI `.task` and
  `values` own view-lifetime work.
- Manual state and UI-observed state live for the app by default. Unused
  automatic and async state may expire. The default grace period is 30 seconds.
- An ephemeral source must use
  `lifetime: .whileObserved(resetToInitial: true)`.
- Tests may seed state before mechanisms start. Seeding creates no turn,
  notice, or reaction.

### Runtime and tools

- The shipping core is the specialized arena with a shared linked-edge pool.
  It makes changed-key notices O(changed) and allocates nothing in a steady
  turn.
- The `CompactArena` package trait turns off specialization to reduce binary
  size without changing behavior.
- Inline `AnyHashable` keys and pool edges won their benchmark decisions.
  Public value references never expose arena slots.
- `coglint` checks six Cog usage rules through SwiftPM build-tool and command
  plugins. The separate `coglint-plugins` package keeps binary artifacts out of
  Cog's root dependency graph.
- Behavior tests use public APIs, injected clocks, continuations, and clear
  signals. They do not depend on timing guesses or a specific core layout.

Open work includes optional `Op` support, deferred reactions, debug history,
persistence helpers, debounce and throttle timing, and any custom hash table
that future benchmarks can justify.

The detailed decision record is in [core design §10](./design/exploration.md#10-decision-record).
Current measurements are in [benchmark results](./impl/benchmarks.md).

<!-- x-release-please-start-version -->

The current published Swift release is 0.4.0.
<!-- x-release-please-end -->
