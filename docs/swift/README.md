# Cog for Swift

Cog is a state library for SwiftUI. It updates only the values and views that
depend on changed state. At the UI edge it works with Apple's `@Observable`
system; inside it uses its own MainActor graph.

This file is the map for the Swift design. The documents share section
numbers, so a reference such as §6.4 works across files.

## Design principles

Four principles guide every API and implementation choice:

1. **Cog should feel simple.** Declaring, reading, and changing state should
   look like normal Swift. Common code should be easy to read and reason
   about; runtime complexity stays behind the API.
2. **Every state read should be correct.** A read must match the latest
   committed source state after settling every dependency it needs. It must
   not expose a torn update, stale derived value, or half-finished change.
   Uncertain async state must be explicit in `CogStatus`.
3. **Cog should minimize runtime overhead.** Avoid needless recomputation,
   allocation, reference counting, locks, and UI updates. Measure competing
   implementations instead of guessing.
4. **Cog state should be singular.** One running app has one authoritative
   `Cogs`, and each mutable fact represented in Cog has one writable source
   in it. Scenes, screens, and features must not create competing contexts or
   mirror sources. A test or preview is a separate runtime with one context.

Correctness and singular state are never traded for speed, and a faster
internal design must keep the common API simple.

## The documents

The design lives in [design/](./design/); the implementation effort lives in
[impl/](./impl/). Read them in this order:

1. **[dump-2026-08-06.md](../dump-2026-08-06.md): history.** Frozen notes from
   the Dart and Flutter design. They explain the original problems but do not
   define the Swift design.
2. **[design/exploration.md](./design/exploration.md): core design (§1–§5,
   §7–§11).** The graph, public API, write rules, async state, SwiftUI
   boundary, open questions, and spike plan.
3. **[design/effects.md](./design/effects.md): effects (§6).** Reactions,
   timers, lifecycle, testing, and work that can outlive the app process.
4. **[design/rx.md](./design/rx.md): Rx mapping (§5.4).** How common stream
   operators map to state dependencies, async policies, and real event
   streams.
5. **[design/perf.md](./design/perf.md): implementation and benchmarks.** The
   planned data-oriented core and the tests that must choose its physical
   layout.
6. **[impl/plan.md](./impl/plan.md): implementation plan.** The spike plan
   turned into milestones, plus the package layout, tooling, CI, and the
   release process.
7. **[impl/scenarios.md](./impl/scenarios.md): test scenarios.** The
   scenario tree that drives red-green implementation: every behavior the
   library promises, written as small user stories and grouped by milestone.
8. **[impl/tasks.md](./impl/tasks.md): task graph.** The milestones decomposed
   into dependency-aware tasks of half an engineering day or less, each with
   explicit closing verification; every scenario is covered by exactly one
   task's _Greens:_ line.

## Building and testing

The package and its M1 simple correctness core are being implemented now. The
SwiftUI boundary and later async slices have not landed yet. The repository is
a SwiftPM package rooted at the git root, with every Swift target under
`swift/`. Commands are mise tasks; `mise tasks` lists them all.

```sh
mise run fmt              # Oxfmt over Markdown/JSON/YAML, swift-format over Swift
mise run fmt:check        # the same checks, writing nothing
mise run test             # the default isolation leg
mise run test:matrix      # all four isolation legs
mise run test:release     # the default leg in release configuration
mise run test:compilefail # batched swiftc pass over swift/CompileFail/
mise run tasks:check      # validate impl/tasks.md against the plan and scenarios
```

Tests run through `tools/swift-test.mjs`, never `swift test` directly: SwiftPM
exits 0 when `--filter` selects nothing, so a raw filtered run can report a
green for work it never ran. The wrapper enumerates the built tests before the
run and checks the executed-test count after it, and gives each leg its own
scratch path. Arguments pass through, as in
`mise run test --filter 'DECL-01|ONE-04' --parallel`.

The four legs are {MainActor-default, nonisolated} ×
{`NonisolatedNonsendingByDefault` on, off}, selected through
`COG_TEST_ISOLATION` and `COG_TEST_NNBD`, which `Package.swift` reads. CI runs
one leg per job using the leg names as wrapper modes (`mainactor-nnbd-on`,
`mainactor-nnbd-off`, `nonisolated-nnbd-on`, `nonisolated-nnbd-off`). Running
the tests needs a full Xcode; the Command Line Tools alone fail with
`no such module 'Testing'`. The root [README.md](../../README.md) records the
pinned version and the runner topology.

## Production, tests, and previews

Production depends on `Cog` only. Call `Cogs.bootstrapApp()` exactly once,
at app launch, and retain the context it returns as the app's ownership handle.
Pass that same object into services, effects, and every scene. A rebuilt scene
receives the existing context; it never bootstraps another one. Features cannot
construct a `Cogs` directly, and there is deliberately no ambient
`Cogs.app` lookup.

```swift
import Cog
import SwiftUI

@main
@MainActor
struct WeatherApp: App {
  private let cogs: Cogs

  init() {
    cogs = Cogs.bootstrapApp()
  }

  var body: some Scene {
    WindowGroup {
      RootScene()
        .cogEnvironment(cogs)
    }
  }
}
```

Every scene receives the same retained object through `.cogEnvironment(cogs)`.
A view reads it with `@Environment(\.cogs) private var cogs`; tests and previews
install their isolated context through the same modifier.

An ordinary test or preview-support target depends on `CogTesting`. Create one
fresh context for that test or preview runtime and pass it through the same
composition boundaries as production. It starts isolated, never occupies the
production-install slot, and needs no reset or uninstall. Multiple tests and
previews may each create a context, but creating a second one partway through a
single runtime would split the state under test.

```swift
import Cog
import CogTesting
import Testing

@MainActor
@Test func counterStartsClean() {
  let countCog = ManualCog<Int>(0)
  let cogs = Cogs.forTesting()

  #expect(cogs.peek(countCog) == 0)
  cogs.commit { c in c[countCog] = 1 }
  #expect(cogs.peek(countCog) == 1)
}
```

Keep `CogTesting` in test or preview-support targets rather than the shipping
app target. Timed tests use `TestClock`, inject it wherever scheduling happens,
and call `advance(by:)` instead of waiting for wall-clock time. Pass that same
clock as `Cogs.forTesting(clock:)` when Cog-owned lifetime grace is under test.
Untimed tests use the default continuous clock.

Only a test whose subject is the production install uses the scoped fixture:

```swift
@MainActor
@Test func appBootstrapIsTheSubject() {
  Cogs.withBootstrappedApp { cogs in
    #expect(Cogs.isBootstrappedApp(cogs))
  }
}
```

`withBootstrappedApp` calls the real guarded bootstrap and removes its temporary
registration in `defer`. Its MainActor closure is synchronous, non-reentrant,
and non-nestable: do not put `await` in it, and do not use it as general test or
preview setup.

## Where things stand (2026-08-13)

These choices are settled; §10 of the core document has the full record.

- `commit` is the only write entry point. Its scalar overload keeps ordinary
  setters compact; its writer overload makes related writes atomic. Ops are
  normal `Cogs` methods. `fileprivate` and `.readOnly` control which code may
  name writable state. A turn ID stops an escaped writer from writing later.
- One outer `commit` is one turn. The context moves through idle,
  accumulating, and flushing. Reactions run at the end of the turn; writes
  from reactions wait in a FIFO queue as new turns. A debug turn-chain guard
  reports long causal chains through an internal diagnostic seam.
- A reaction registered during a flush never runs reentrantly. Its initial
  tracking run joins that flush's reaction tail in registration order, after
  already-scheduled reactions and before queued write-back turns.
- Before notifying the UI, Cog settles every changed path that has a live
  consumer. Unused paths stay lazy.
- Tracked reads use the active capability's subscript: `c[valueReference]` in
  selectors and reactions, and `cogs[valueReference]` at the UI boundary. The
  context owns the tracking operation, while non-tracking reads remain visibly
  different as `c.peek(valueReference)` or `cogs.peek(valueReference)`.
  Actions and other escaping closures must use the one-shot spelling. Public
  Observation cannot tell Cog whether the subscript found an active UI
  consumer, so Cog does not guess or emit a false-positive missing-consumer
  warning; that diagnostic is deferred until the framework exposes an exact
  public query.
- Value references (`Cog<T>` and `ManualCog<T>`) name state by descriptor and key. A value reference
  is a value; its identity lives in an internal final-class descriptor plus
  key. Boxes create keyed value references without allocating new descriptors. The exact
  in-memory value-reference layout is not settled; benchmarks will compare inline keys,
  interned keys, and generic keyed value references.
- State declaration names expose that shape at the use site: one keyless value
  reference ends in `Cog` (`currentZipCog`), while a box ends in plural `Cogs`
  (`weatherForecastCogs`). Qualifiers such as `Source` precede the suffix. The
  app runtime remains the ordinary local `cogs`; values read from the graph use
  unsuffixed domain names.
- Async reads are total and value-first: `c[valueReference]` returns the last
  accepted success, resting on the declaration's default until one exists, and
  the request lifecycle reads through the `status` lens (`c.status[...]`,
  `cogs.status[...]`), which exists only for async references. Every declaration
  states the resting invariant with `default:`, including `default: nil` for
  optional values.
- Async selectors read dependencies synchronously, then return `Work.run` or
  `Work.stream`. The first read starts work and publicly begins at
  `kind == .pending`, `value == default`, and `hasSucceeded == false`; there is
  no observable `initial` kind. `CogStatus.value` is total in every kind, while
  `hasSucceeded` keeps a successful optional `nil` distinct from the resting
  default. SwiftUI observes `kind`, `value`, `hasSucceeded`, `error`, and
  `isLoading` independently, registering only fields a body reads. `.latest`
  is the default policy.
  Streams allow only `.latest`.
- `.exhaustLatest` finishes current work, then catches up once. True event
  dropping belongs to imperative ops.
- `Cogs` owns state, reactions, and its app-lifetime `effects` group. A
  shorter-lived feature owns a separate final-class `EffectGroup`; those
  handles cancel safely more than once. A
  cancelled group is terminal; adding a reaction token afterward synchronously
  cancels the token without retaining it, and a task requested afterward is
  already cancelled when `task` returns. Neither operation reopens the group.
- Production creates one app-wide `Cogs` and injects it above all scenes.
  Screens and features share it. Tests and previews create one isolated
  context for their runtime.
- Production construction is guarded. `Cogs.bootstrapApp()` creates the one
  production context and fails fast on a second call; the plain initializer is
  `package`, so feature code cannot name it. The `CogTesting` product adds
  `Cogs.forTesting()` for a test or preview runtime, which never registers
  as the production context.
- The context returned by `bootstrapApp()` is the app's ownership handle. The
  app passes it to effects, services, and scenes; views receive it through the
  planned M2 environment boundary, and ops are instance methods on it. Current
  M1 composition passes the same object explicitly. There is no ambient
  `Cogs.app`. Tests of production installation use a synchronous scoped
  fixture from `CogTesting`, so they cannot leak global install state across
  the suite.
- Manual state and states seen by the UI live for the app context by default.
  Graph-only derived and async states may be released when unused. Query caches
  have their own retention rules. A `whileObserved` declaration with no
  explicit grace uses the context default: 30 seconds in production, with an
  explicit `CogTesting` override for deterministic timed tests.
- Non-tracking peeks (`c.peek` in a selector or reaction, and one-shot
  `cogs.peek` outside) skip
  the dependency edge but still settle the value they return; they are never
  stale. A synchronous derived or async peek is transient demand: without a
  durable consumer it renews normal `whileObserved` grace, and expiry releases
  the state. Peeking or refreshing a never-read async value starts exactly one
  initial run with `kind == .pending`, `value == default`, and
  `hasSucceeded == false` without a dependency, subscription, or Observation
  boundary; expiry also cancels its work and rejects late results. Exported
  streams (`cogs.values(of:)`) start from the current settled value and never
  make a commit wait: `.newest(1)` may skip turns for a slow reader,
  `.oldest(n)` delivers the oldest n in order and drops newer while full, and
  `.unbounded` delivers everything.
- External `@Observable` inputs publish the newest post-mutation value at each
  propagation boundary; several mutations may coalesce. The pre-iOS-26
  one-shot shim internally acknowledges re-arming for deterministic tests, but
  its small disarmed race remains a documented platform limitation.
- Debug-only `CogTesting.seed` stages a value and pushes dirty flags like a
  write, but records no turn, sends no notices, and runs no reactions. Tests
  may seed after effects install; the next real turn settles what the seed
  dirtied. Apps importing only `Cog` cannot seed.
- Dynamic cycles are programmer errors. Diagnostics show the keyed path.
  Synchronous selectors do not throw in v1.
- Derived computation is read-only through selector execution, dependency
  reconciliation, custom equality, and result publication. A commit attempted
  in that region fails immediately in every build, names the cog/key and turn,
  and tells the caller to invoke the op outside derived computation, from event
  handling or a reaction.
- The runtime will use a data-oriented arena. Public value references remain names, never
  arena slot handles.
- Tests are fully optimistic, as fast and cheap as possible, and as
  implementation agnostic as possible: every wait is a definite injected
  signal (clocks, continuations, acknowledgements), host-side `swift test` is
  the default home with injected time everywhere, and behavior tests observe
  the public surface before any diagnostic seam — so the suite must pass
  unchanged across the planned core swap. The normative statement is the
  "Testing constraints" section of impl/scenarios.md.
- Implementation runs from a checked dependency graph of half-day tasks. Each
  task has one type, explicit prerequisites and closing verification, and ends
  green; scenario credit requires proving the whole story against real
  infrastructure. Core swaps integrate by behavior group, and every release
  separates its candidate gate, tag, and post-release verification. The
  normative rules are in impl/tasks.md.

Still open: how much `Op` support v1 needs, optional deferred reactions,
debug-history tools, and persistence helpers. Also open are several edge
behaviors: what a stream's status does when its sequence ends or throws, whether
equal stream elements commit distinct turns, whether a failed `.queue` run
stops the queue, and debounce/throttle timing modifiers (deferred backlog).
Value-reference layout, edge layout, and hash tables also remain open until
benchmarks choose them.

## Next steps

[impl/plan.md](./impl/plan.md) is the execution plan,
[impl/scenarios.md](./impl/scenarios.md) is its test-scenario tree, and
[impl/tasks.md](./impl/tasks.md) is its half-day task breakdown. Build the
simple correctness version first, then the SwiftUI boundary, then a first
async slice for a usable 0.1.0. Port `js-reactivity-benchmark` and compare value-reference layouts before
building the data-oriented core, and measure that core against the simple
version, swift-state-graph, and raw `@Observable`.
