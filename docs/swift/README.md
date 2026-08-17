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
3. **[design/mechanisms.md](./design/mechanisms.md): mechanisms (§6).** The
   bundled home for every side effect: reactions, timers, gated scopes,
   bootstrap registration, testing, and work that can outlive the app
   process.
4. **[design/rx.md](./design/rx.md): Rx mapping (§5.4).** How common stream
   operators map to state dependencies, async policies, and real event
   streams.
5. **[design/perf.md](./design/perf.md): implementation and benchmarks.** The
   planned data-oriented core and the tests that must choose its physical
   layout.
6. **[design/prior-art.md](./design/prior-art.md): prior-art review.** The
   swift-state-graph review that preceded the 0.1.0 public-name freeze: how the
   two libraries line up, tracked reads versus capture lists, and the
   name-by-name decisions that came out of it.
7. **[design/lint.md](./design/lint.md): lint tooling.** The accepted
   first-party linter that turns the usage conventions into an executable
   style guide: a SwiftSyntax tool developed in-repo as a nested
   `swift/Lint` package and shipped behind SwiftPM plugins, the first six
   rules, their Cog-coupled release, and the rollout.
8. **[impl/plan.md](./impl/plan.md): implementation plan.** The spike plan
   turned into milestones, plus the package layout, tooling, CI, and the
   release process.
9. **[impl/scenarios.md](./impl/scenarios.md): test scenarios.** The
   scenario tree that drives red-green implementation: every behavior the
   library promises, written as small user stories and grouped by milestone.
10. **[impl/tasks.md](./impl/tasks.md): task graph.** The milestones decomposed
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
`mise run test --filter 'DECL-01|ONE-05' --parallel`.

The four legs are {MainActor-default, nonisolated} ×
{`NonisolatedNonsendingByDefault` on, off}, selected through
`COG_TEST_ISOLATION` and `COG_TEST_NNBD`, which `Package.swift` reads. CI runs
one leg per job using the leg names as wrapper modes (`mainactor-nnbd-on`,
`mainactor-nnbd-off`, `nonisolated-nnbd-on`, `nonisolated-nnbd-off`). Running
the tests needs a full Xcode; the Command Line Tools alone fail with
`no such module 'Testing'`. The root [README.md](../../README.md) records the
pinned version and the runner topology.

## Production, tests, and previews

Production depends on `Cog` only. Call `Cogs.bootstrapApp(mechanisms:)`
exactly once, at app launch, listing every mechanism the app runs, and retain
the context it returns as the app's ownership handle. When bootstrap returns,
every mechanism is live; there is no later installation step. Use the retained
object at the composition root to install the SwiftUI environment above every
scene. A rebuilt scene receives the existing context; it never bootstraps
another one. Features cannot construct a `Cogs` directly, and there is
deliberately no ambient `Cogs.app` lookup.

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

Every scene receives the same retained object through `.cogEnvironment(cogs)`.
Every view that interacts with Cog declares
`@Environment(\.cogs) private var cogs` itself. Views never accept, store, or
forward `Cogs` in their initializers; intermediate views pass domain values and
identities only. Tests and previews host their view hierarchy under the same
modifier with an isolated context.

An ordinary test or preview-support target depends on `CogTesting`. Create one
fresh context for that test or preview runtime with
`Cogs.forTesting(seeding:mechanisms:)`; both parameters default to nothing, and
the seeding closure runs before any mechanism's `operate`, so a test arranges
state first and then watches mechanisms come alive against it. Use the context
directly at non-view test boundaries, or install it above a hosted view
hierarchy with `.cogEnvironment(cogs)`. It starts isolated, never occupies the
production-install slot, and needs no reset or uninstall. Multiple tests and
previews may each create a context, but creating a second one partway through
a single runtime would split the state under test.

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

## Where things stand (2026-08-14)

These choices are settled; §10 of the core document has the full record.

- `commit` is the only write entry point. Its scalar overload keeps ordinary
  setters compact; its writer overload makes related writes atomic. Ops are
  normal methods in `CogOps` extensions, so `Cogs` and a mechanism's
  controller share every op. `private` or `fileprivate` plus `.readOnly`
  control which code may name writable state. A turn ID stops an escaped writer from writing later.
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
- Value references (`Cog<T>` and `ManualCog<T>`) name state by descriptor and
  key. A value reference is a value; its identity lives in an internal
  final-class descriptor plus key. Boxes create keyed value references without
  allocating new descriptors. Keyed-diamond and churn benchmarks selected
  inline `AnyHashable?` for v1; the interned-token and generic-keyed layouts
  remain test-and-benchmark-only comparison builds.
- State declaration names expose that shape at the use site: one keyless value
  reference ends in `Cog` (`currentZipCog`), while a box ends in plural `Cogs`
  (`weatherForecastCogs`). Qualifiers such as `Source` precede the suffix. The
  app runtime remains the ordinary local `cogs`; values read from the graph use
  unsuffixed domain names.
- Application read sites make that boundary explicit by immediately binding
  each graph read to its unsuffixed domain local. This applies to selectors and
  reactions as well as SwiftUI. For example, a status read is
  `let weatherForecast = cogs.status[weatherForecastCogs[zip]]`. It still uses
  `weatherForecast`, not `weatherForecastStatus`; its `CogStatus` type carries
  the distinction. Later field access preserves field-level Observation.
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
- Side effects bundle into first-class `Mechanism` values — a protocol with a
  defaulted `name` and one `operate(_:)` requirement — specified only at
  bootstrap and operated synchronously in array order before bootstrap
  returns. `operate` receives a curated `MechanismController`, never raw
  `Cogs`: registration (`run`, `watch`, `task`, `whenever`), untracked
  `peek`, and the shared ops surface. A lifetime shorter than the app is a
  state-gated `whenever` scope: the gate's fall cancels everything the scope
  registered, and its next rise re-runs the body fresh. There is no public
  reaction token or effect group, and no late registration API; view-lifetime
  work stays with SwiftUI `.task` and `values`. The runtime retains each
  supplied mechanism value until teardown, when it cancels the mechanism's
  scope before releasing that value. Delegate work that may arrive later uses
  a weak controller callback, never raw `Cogs`; the callback becomes inert
  when its scope ends.
- Production creates one app-wide `Cogs` and injects it above all scenes.
  Screens and features share it. Tests and previews create one isolated
  context for their runtime.
- Production construction is guarded. `Cogs.bootstrapApp(mechanisms:)`
  creates the one production context, operates its mechanisms, and fails fast
  on a second call; the plain initializer is `package`, so feature code cannot
  name it. The `CogTesting` product adds `Cogs.forTesting(seeding:mechanisms:)`
  for a test or preview runtime, which seeds before any `operate` and never
  registers as the production context.
- The context returned by `bootstrapApp(mechanisms:)` is the app's ownership
  handle. The app retains it, passes explicit context only at non-view
  composition boundaries such as isolated test harnesses, and injects it above
  every scene. Every consuming view resolves it directly through `\.cogs`; no
  view accepts or forwards it. Ops extend `CogOps`, and there is no
  ambient `Cogs.app`. Tests of production installation use a synchronous scoped
  fixture from `CogTesting`, so they cannot leak global install state across
  the suite.
- Manual state and states seen by the UI live for the app context by default.
  Graph-only derived and async states may be released when unused. Query caches
  have their own retention rules. A `whileObserved` declaration with no
  explicit grace uses the context default: 30 seconds in production, with an
  explicit `CogTesting` override for deterministic timed tests. An ephemeral
  source opts out of app lifetime with
  `lifetime: .whileObserved(resetToInitial: true)`, which is the only spelling
  Cog accepts for a source: releasing one can only start it over, so the
  contradictory `false` traps at the declaration.
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
  write, but records no turn, sends no notices, and runs no reactions. The
  factory's seeding phase precedes every mechanism's `operate`; seeding after
  bootstrap remains safe, because the next real turn settles what the seed
  dirtied. Apps importing only `Cog` cannot seed.
- Dynamic cycles are programmer errors. Diagnostics show the keyed path.
  Synchronous selectors do not throw in v1.
- Derived computation is read-only through selector execution, dependency
  reconciliation, custom equality, and result publication. A commit attempted
  in that region fails immediately in every build, names the cog/key and turn,
  and tells the caller to invoke the op outside derived computation, from event
  handling or a reaction.
- The runtime uses a data-oriented arena with a shared linked edge pool. Public
  value references remain names, never arena slot handles.
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
- Public names are frozen for 0.1.0 as they stand. The chartered prior-art
  review reconsidered thirteen of them against swift-state-graph and renamed
  none; [design/prior-art.md](./design/prior-art.md) records the matrix, the
  reasoning, and the one name with a revisit trigger.
- First-party lint tooling is settled as a syntax-only `coglint` developed in
  a nested package and shipped as a prebuilt binary behind SwiftPM plugins. Its
  six initial rules cover declarations, view/runtime boundaries, primitive
  ownership, bootstrap-time state, source privacy, and multi-read runtime
  helpers. Cog, the linter, and their `Cog.docc` rule pages share one release;
  the root manifest is the v1 distribution unless an unused-artifact fetch
  measurement selects the version-coupled manifest-repository fallback.

Still open: how much `Op` support v1 needs, optional deferred reactions,
debug-history tools, persistence helpers, the lint products' final names and
severity policy, and the stable rule-page URL shape. Also open are several
edge behaviors: what a stream's status does when its sequence ends or throws,
whether equal stream elements commit distinct turns, whether a failed `.queue`
run stops the queue, and debounce/throttle timing modifiers (deferred backlog).
Custom hash tables also remain open until benchmarks justify them. Inline
`AnyHashable` value references and the shared linked edge pool are selected by
the measurements in design/perf.md §9.6.

## Prior art

Cog is not the first Swift graph. Before freezing its public names it read
[swift-state-graph](https://github.com/VergeGroup/swift-state-graph), by
Hiroshi Kimura (muukii) and the VergeGroup authors, and credits it for arriving
first at the shape both libraries share: a dependency graph with dirty marking,
recomputation deferred to the read that needs it, and a library that meets
SwiftUI at `@Observable` instead of replacing it. Cog's own lineage for the
graph algorithms — SolidJS, Reactively, and the js-reactivity-benchmark
scenarios — is credited in [design/perf.md](./design/perf.md).

Cog diverges deliberately in five places: one app-wide `Cogs` owns every state
instead of state living on the objects that declare it; the reader is a value
passed to a selector rather than ambient thread-local tracking; lifetime is
declared per state kind rather than left to ARC; boxes make keyed value
references from one declaration; and async state, with its status and policies,
is a first-class state kind. [design/prior-art.md](./design/prior-art.md) is the
full review.

## Next steps

[impl/plan.md](./impl/plan.md) is the execution plan,
[impl/scenarios.md](./impl/scenarios.md) is its test-scenario tree, and
[impl/tasks.md](./impl/tasks.md) is its half-day task breakdown. Build the
simple correctness version first, then the SwiftUI boundary, then a first
async slice for a usable 0.1.0. The benchmark port selected inline value
references; next, build the data-oriented core and measure it against the
simple version, swift-state-graph, and raw `@Observable`.
