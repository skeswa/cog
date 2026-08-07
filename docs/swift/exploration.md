# Cog for Swift: core design

*August 6, 2026*

*See [README.md](./README.md) for the document map.*

Cog is a fine-grained state library for SwiftUI. “Fine-grained” means that a
change updates only the derived values and views that used it. Cog uses
Apple's Observation system at the UI edge and its own dependency graph
inside.

This document covers the core design. [rx.md](./rx.md) holds §5.4, and
[effects.md](./effects.md) holds §6.

The main finding is simple: Swift is a strong fit. The MainActor gives the
graph one safe execution lane. Observation lets SwiftUI track individual
values. Swift access control can enforce write ownership. Cog must add the
parts the platform lacks: cached derived state, consistent updates, keyed
families, named turns, and async policies.

Three principles judge the design:

1. **Feel simple:** normal use should look like ordinary Swift and require few
   concepts.
2. **Make every state read correct:** a read must see the latest committed
   sources after settling every dependency needed for that value.
3. **Minimize runtime overhead:** do no more computation, allocation, or UI
   work than the result needs.

The first two constrain the third. An optimization must not weaken read
correctness or make the common API harder to understand.

---

## 1. What the platform gives us, and what it doesn't

### 1.1 Observation is the UI boundary, not the graph

`@Observable` records which properties a view reads. When one changes,
SwiftUI can update that view. A Cog node can join this system by calling
`ObservationRegistrar.access` on reads and `withMutation` after real changes.
No view adapter is needed.[^observation-mechanics]

Observation does not provide Cog's inner graph:

| Cog needs | Observation provides |
| --- | --- |
| Cached derived values | Nothing; computed properties run on every read. |
| One consistent snapshot | Nothing below iOS 26; old callbacks start at `willSet`. |
| Explicit turns | iOS 26 `Observations` batches between suspension points, but has no explicit transaction block. |
| Continuous tracking | One-shot tracking until Swift 6.4 and its newer OS runtime. Manual re-arming can miss changes. |
| Equality checks | Nothing; setting an equal value still sends a notice. |
| Keyed families, async values, write control | Nothing. |

Two platform rules shape Cog:

- Tracking sees only synchronous reads in the tracked scope. Reads in later
  closures or on another thread do not count. Cog makes this rule clear with
  the synchronous `c.get` API.
- The registrar is thread-safe, but observed storage is not. State still
  needs one owner.

### 1.2 The graph stays on the MainActor

New Swift app targets default to the MainActor. This means UI state runs on
one ordered executor unless code asks for concurrency. That is Cog's desired
model.

The graph is therefore **MainActor-confined**. It is not its own actor and is
not protected by a lock. A synchronous turn cannot interleave with another
turn. Async cogs and ops may do background work, then return results to the
MainActor.

Relevant Swift tools are:

- Default MainActor isolation makes top-level cog declarations natural.
- `nonisolated(nonsending)` lets async work remain on the caller's actor.
- `@concurrent` explicitly moves expensive work to the global executor.
- `Task.immediate` can start subscription work without a one-tick delay on
  iOS 26.
- Task names improve Instruments and debugger output.
- Swift 6.4 adds cancellation shields, typed-throws tasks, and `~Sendable`.

An actor of Cog's own would be re-entrant at each `await`. A lock-based graph
would bring back torn UI reads and require every value to be `Sendable`.
Moving only expensive computation gives most of the benefit at much lower
cost. §2.5 and Appendix C cover the alternatives.

### 1.3 The ecosystem leaves room for Cog

No current Swift library combines this platform fit with all three principles
at Cog's intended scale:

- swift-state-graph has cached derived values and Observation support, but
  dependencies use capture lists and it has no turn model.
- swiftui-atom-properties has keyed and async atoms, scopes, effects, and
  release rules, but uses the older `ObservableObject` model and centers the
  view layer.
- TCA is powerful but has a much larger API and code footprint. Cog should
  stay close to normal values and methods.
- Combine is stable but largely frozen. `AsyncSequence` and Observation are
  the newer platform surfaces.
- Swift has no clear winner for keyed query caching, stale data, and
  invalidation.

Modern JavaScript signal systems agree on the main graph algorithm. Writes
push cheap dirty flags. Reads pull new values only when needed. Equal results
stop further work. Cog follows that push-pull model. Appendix B links the
research; Appendix D keeps the fuller ecosystem notes.

---

## 2. The core architecture

### 2.1 Three layers

```text
┌──────────────────────────────────────────────────────┐
│ SwiftUI / UIKit                                      │
│ Views read cogs through normal Observation tracking. │
├──────────────────────────────────────────────────────┤
│ Observation boundary                                 │
│ One registrar-backed object per UI-seen cog and key. │
├──────────────────────────────────────────────────────┤
│ Cog graph on the MainActor                           │
│ State, derived values, turns, async work, reactions. │
└──────────────────────────────────────────────────────┘
```

Cog owns the inner graph. Observation is only the boundary.

Using Observation inside the graph would cause three problems:

1. Older APIs use one-shot `willSet` callbacks, so re-arming is racy and
   values may be read mid-change.
2. Chained callbacks recreate the “telephone problem”: each link updates at a
   different time.
3. The APIs suited to continuous graph tracking require newer OS versions.

An owned graph keeps the main feature set at iOS 17. New Observation APIs can
still link outside objects into Cog (§8). If needed later, Perception could
back-deploy the UI boundary as far as iOS 13.

### 2.2 Lazy reads keep state consistent

Terms used below:

- A **source** is writable state.
- A **derived cog** computes a value from other cogs.
- A **node** is one source or derived value in one `Cogtext`.
- A **turn** is one outermost `commit` and the work it causes.
- A **hot root** has a live UI, reaction, or stream consumer. A cold node does
  not.

Here, a “correct read” means a value derived from all source writes in the
latest completed turn. It does not mean that outside data is always fresh. An
async cog may still be pending or show a previous value, but `CogPhase` makes
that state explicit. During a commit, reads through its `Writer` instead see
that turn's staged source values, so read-modify-write remains correct.

Cog does not recompute the whole graph after a write. It marks possible
changes, then computes a derived cog when a consumer needs it. That read first
updates its parents. Equality checks stop work when the value stayed the same.
The reader therefore gets one consistent result, never a half-finished wave.

At the end of a turn, Cog must also serve push-based consumers:

1. Commit changed source values and ignore equal writes.
2. Mark downstream nodes dirty without running selectors.
3. Settle dirty hot roots. Cold branches stay lazy.
4. Notify changed UI nodes and streams.
5. Run changed reactions in registration order.

Each outer `commit` is its own turn, even if two commits run in the same event
handler. This gives each change a name and history record. A slow state stream
may still coalesce values with its buffer policy (§8).

The commit point is structural. Writes require the `Writer` passed into
`commit`; when the outer body exits, Cog flushes the turn. Nested commits join
it. A writer carries a turn ID, so saving it and calling it later fails.

### 2.3 Descriptors name state; `Cogtext` stores it

A top-level declaration is a light descriptor, not a live global value. Each
`Cogtext` stores its own node for a descriptor and optional key.

This split gives Cog:

- **Keyed families.** A box plus a key finds one node.
- **Clean tests.** Each test creates a new `Cogtext`; no global reset is
  needed.
- **One history owner.** The context records turns and recomputations.
- **Local scopes.** A screen may own a child context and private descriptors.

Descriptors are final classes. Their `ObjectIdentifier` gives stable identity
for the process. Human labels use an explicit `name:` or the captured
`fileID:line`; users never see the object identifier. A future optional macro
could infer names without changing identity.

The cost is that reads need a context: `c.get(ref)` inside a selector and
`cogs.get(ref)` outside. That context is also what tracks dependencies and
records history.

### 2.4 Dependencies are captured on every run

Dependencies are exactly the cogs read with `c.get` during the last run.
Conditions and early returns are valid. On the next run, every edge must be
read again to stay attached.

The runtime places the current consumer in a MainActor tracking slot while it
runs a selector or reaction.[^tracking-storage] Each `get` links the producer
to that consumer.

Rules:

- Reuse dependency edges across runs where possible. Remove any edge not read
  again. The physical edge layout remains benchmark-gated (perf §3.3).
- Track CLEAN, CHECK, and DIRTY state plus version numbers. This avoids work
  when no parent value really changed.
- Compare old and new values after every computation. Use `Equatable` when
  available, allow a custom `equals:`, and treat non-equatable values as
  changed.
- Mark a node while its selector runs. Reading any marked node is a cycle.
  Fail in every build and show the full descriptor-and-key path. An internal
  seam lets tests inspect diagnostics without crashing the test process.
- Synchronous selectors do not throw in v1. Use `Result` for fallible sync
  domain work and `CogPhase` for async failures.
- `c.curr` exposes the cog's prior value so a selector may keep or fold it.

The benchmark port must test diamonds, deep graphs, broad graphs, changing
dependencies, and cycles.

### 2.5 Why the graph is not off-main

Three off-main designs are possible, but none fits the UI boundary:

| Design | Main problem |
| --- | --- |
| Graph on another actor | SwiftUI reads are synchronous and cannot `await`; actor reentrancy can also interleave turns. |
| Locked graph on any thread | A view can read two cogs from different turns, and all values become `Sendable`. |
| Background graph with snapshots | Snapshots are coherent, but text fields need immediate write-then-read behavior. Local UI state would need a second system. |

Graph bookkeeping is cheap. User code inside a selector is the likely cost.
Keep small derived values on main and use `@concurrent` work in an `AsyncCog`
for expensive computation. Network, database, and sensor producers can work
elsewhere and enter through an op.

If a real server-side use case appears, prefer separate single-executor
contexts linked by explicit async edges. Only MainActor contexts would attach
to views. Appendix C gives the full trade-off analysis.

---

## 3. API sketch

The examples assume a Swift 6.2 module with default MainActor isolation.
Library declarations must still state isolation explicitly (§7).
The common path uses plain declarations, reads, methods, and bindings so the
graph machinery does not dominate application code.

### 3.1 Declarations

```swift
// WeatherState.swift

fileprivate let weatherServiceSource = ManualCog<WeatherService>(.live)
let weatherService = weatherServiceSource.readOnly

fileprivate let weatherReportSource = ManualCogBox<Weather?, ZipCode>(nil)
fileprivate let heatAdvisorySource  = ManualCogBox<Bool, ZipCode>(false)
fileprivate let currentZipSource    = ManualCog<ZipCode?>(nil)

let weatherReport = weatherReportSource.readOnly
let currentZipCode = currentZipSource.readOnly

let isSunny = CogBox<Bool, ZipCode> { c, zip in
    switch c.get(weatherReport[zip])?.kind {
    case .clear, .partlyCloudy: true
    default: false
    }
}

let isNiceOutside = CogBox<Bool, ZipCode> { c, zip in
    guard let report = c.get(weatherReport[zip]) else { return false }
    guard c.get(isSunny[zip]) else { return false }
    let advisory = c.get(heatAdvisorySource[zip])
    return report.temperatureF > 60
        && report.temperatureF < 90
        && !advisory
}

let isNiceOutsideHere = Cog { c in
    guard let zip = c.get(currentZipCode) else { return false }
    return c.get(isNiceOutside[zip])
}
```

The public forms are:

| Declare | Example | Read |
| --- | --- | --- |
| One derived value | `Cog<Bool> { ... }` | `c.get(ref)` → `Bool` |
| A derived family | `CogBox<Bool, ZipCode> { ... }` | `c.get(box[zip])` |
| One source | `ManualCog<ZipCode?>(nil)` | Read normally; write `w[ref] = zip` |
| A source family | `ManualCogBox<Weather?, ZipCode>(nil)` | `w[box[zip]] = report` |
| One async value | `AsyncCog<Forecast>(.latest) { ... }` | `CogPhase<Forecast>` |
| An async family | `AsyncCogBox<Weather, ZipCode>(.latest) { ... }` | Full phase or `.latest` value (§5.1) |

Four rules keep these forms consistent:

1. **Refs are the only inputs to runtime APIs.** `Cog<T>` is readable;
   `ManualCog<T>` is readable and writable. Identity is descriptor plus key.
2. **Boxes create refs.** `box[key]` returns a ref. A keyless declaration is
   the same system already bound to its only node.
3. **Production kind does not change the read type.** Manual, derived, and
   async describe how a value is made. Async refs are ordinary
   `Cog<CogPhase<T>>` refs with a `.latest` projection.
4. **Frequent call sites stay short.** `get`, `commit`, `w[...]`, and
   `box[key]` are common. Longer names such as `ManualCogBox` appear only at
   declarations.

The semantic shape is settled, but the physical ref layout is not. The first
build uses inline `AnyHashable?`. Benchmarks will compare it with interned key
tokens and generic keyed refs. The public ref stays resilient, not `@frozen`,
until data chooses a winner (perf §4 and §9).

Keys pass through normal lexical capture, as `zip` does above. There is no
hidden key flow. Nodes appear lazily per descriptor and key. A manual family's
initial value may also be a key-based closure.

### 3.2 Ops and turns

```swift
extension Cogtext {
    func checkWeather(_ zip: ZipCode) async throws {
        let service = read(weatherService)

        async let report = service.weather(for: zip)
        async let advisories = service.advisories(for: zip)
        let (r, a) = try await (report, advisories)

        commit { w in
            w[weatherReportSource[zip]] = r
            w[heatAdvisorySource[zip]] = a.contains { $0 is HeatAdvisory }
        }
    }

    func useCurrentLocation(_ zip: ZipCode) {
        commit { w in w[currentZipSource] = zip }
    }
}
```

`commit(_ name: String = #function, _ body: (Writer) -> Void)` is the only
write primitive.

- Only `Writer` can change a source. It supports read and write, so
  `w[count] += 1` works.
- Each writer carries an unforgeable turn ID and checks that its context is
  still accumulating that turn. An escaped writer cannot be used later.
- `#function` names the turn without extra code. An op is just a normal
  `Cogtext` method that calls `commit`. Pass a custom name only when needed.
- Access control decides which source refs the method may name (§4).

A context has three phases:

1. **Idle:** an outer commit starts a turn.
2. **Accumulating:** commit bodies stage writes. Nested commits join the same
   turn and turn ID.
3. **Flushing:** the outer body has returned. A new commit now waits in a FIFO
   queue as a later turn.

The flush order is normative:

1. Compare pending and current source values. Keep real changes and discard
   equal writes.
2. Push dirty flags from changed sources. Do not run selectors yet.
3. Pull dirty hot roots: UI boundaries, active stream exports, and current
   reaction dependencies. Leave cold branches dirty.
4. Notify changed boundary nodes and offer changed stream values to each
   subscriber's buffer.
5. Run changed reactions in registration order and capture their new
   dependencies.
6. Return to idle, or drain queued write-back turns in FIFO order.

First-class `Op` values with call status may come later. They are not needed
for v1 because plain methods already get write control and turn names.

### 3.3 Reactions

```swift
let token = cogs.run { c in
    if c.get(isNiceOutsideHere) {
        notifier.alert("It is nice outside!")
    }
}
```

A reaction runs once when registered so it can record dependencies. It runs
again after a turn changes one of them, always against settled state. The
returned final-class token cancels safely more than once and also cancels on
deinit. Copies refer to the same registration. §6 covers effect ownership,
timers, registration, and reaction write-back.

### 3.4 SwiftUI

```swift
struct WeatherCard: View {
    @Environment(\.cogs) private var cogs
    let zip: ZipCode

    var body: some View {
        let report = cogs.get(weatherReport[zip])
        let nice = cogs.get(isNiceOutside[zip])

        VStack {
            Text(report.map { "\(Int($0.temperatureF.rounded()))°F" }
                 ?? "No weather report yet")
            Text(nice ? "Go outside!" : "Stay in.")
            Button("Check the weather") {
                Task { try await cogs.checkWeather(zip) }
            }
        }
    }
}
```

`cogs.get` reads through the node's registrar. SwiftUI then tracks that exact
descriptor and key. The view updates only if one of those values really
changes. There is no special view, hook, or property wrapper. The app injects
one `Cogtext` through the environment.

SwiftUI does not tell Cog when it stops watching a registrar object. Any node
that reaches this UI boundary stays pinned until its context dies (§5.3).

Views should not create raw writable bindings because sources are
`fileprivate`. The state file exports a domain binding:

```swift
// WeatherState.swift
extension Cogtext {
    var currentZipBinding: Binding<ZipCode?> {
        binding(for: currentZipCode) { w, zip in
            w[currentZipSource] = zip
        }
    }
}

// A view
TextField("ZIP", value: cogs.currentZipBinding, format: .zipCode)
```

`binding(for:)` pairs a tracked read with a named commit. The state file still
lists every write path. For a one-time untracked read, use `cogs.read(...)`.

---

## 4. Write ownership

Swift access control replaces the custom lints proposed for Dart:

- Declare writable sources `fileprivate`, or `private` inside a type. Only
  that file or type can name them.
- Expose `.readOnly` refs or derived cogs.
- Put ops, bindings, and test seams beside the sources they may write.

Callers can use `try await cogs.checkWeather(zip)` but cannot reach
`weatherReportSource`. A review can find every possible write by searching one
file's commit blocks.

`@testable import` cannot see `fileprivate` sources. The owning file must
publish narrow debug-only seed or stub methods. §6.6 shows quiet `seed` helpers
and loud commit helpers. Making all sources `internal` would weaken the rule
from one file to one module.

---

## 5. Async cogs

### 5.1 Values and work

Async state uses one phase type and keeps the last good value:

```swift
enum CogPhase<Value> {
    case initial
    case pending(previous: Value?)
    case success(Value)
    case failure(any Error, previous: Value?)

    var latestValue: Value? { ... }
    var isLoading: Bool { ... }
}
```

There is no failure type parameter in v1. Typed throws may support a typed
variant after the required Swift and OS versions are practical.

An async selector is synchronous and tracked. It reads dependencies, then
returns a description of async work:

```swift
let weatherReport = AsyncCogBox<Weather, ZipCode>(.latest) { c, zip in
    let service = c.get(weatherService)
    return .run { try await service.weather(for: zip) }
}
```

`Work` has two forms:

- `.run { ... }` returns one value. The result commits as one turn.
- `.stream(sequence)` commits each sequence element as its own turn.

This split prevents hidden async tracking bugs. Every `c.get` happens before
the work starts, so no read can silently stop tracking after an `await`.
Changing a dependency reruns the selector and creates new work. The policy in
§5.2 decides what happens to the old work.

Read either the full phase or its last good value:

```swift
c.get(weatherReport[zip])
c.get(weatherReport.latest[zip])
```

The `.latest` projection lets downstream code read a manual `Weather?` and an
async weather value in the same shape. Use `AsyncCog` for async derived state.
Use an op for an imperative action. A forced refresh can be an op such as
`cogs.refresh(weatherReport[zip])`.

### 5.2 Scheduling policies

| Policy | Behavior | Common stream name |
| --- | --- | --- |
| `.latest` (default) | Cancel old work; only the newest generation may commit. | `switchMap` |
| `.queue` | Run requests in order. | `concatMap` |
| `.exhaustLatest` | Finish current work, coalesce changes, then catch up once. | exhaust with latest catch-up |
| `.merged` | Allow overlapping runs; each result is its own turn. | `merge` / `flatMap` |

Cancellation alone is not enough. Old work may finish before it notices
cancellation, so every run gets a generation number. The MainActor commits a
result only if that generation is still current.

Each visible pending, success, or failure state is a turn. Replacing cancelled
work does not publish a failure. A future explicit cancel API must define the
phase it writes.

True exhaust behavior drops events while busy. A derived value cannot forget
dependency changes and still represent current state, so `.exhaustLatest`
catches up once. True exhaust belongs to imperative ops.

Work stays on the MainActor by default and suspends at `await`. Expensive,
`Sendable` work can opt into `@concurrent`. Internal tasks use descriptor names
and keys for Instruments.

**Streams allow only `.latest`.** A queued infinite stream blocks the queue
forever. An exhausted infinite stream never catches up. The type system should
enforce this:

```swift
init(_ policy: LatestPolicy,
     _ selector: (C) -> Work<Value>)       // .run or .stream

init(_ policy: OrderedPolicy,
     _ selector: (C) -> RunWork<Value>)    // .run only
```

`.latest` is the only `LatestPolicy`. `.queue`, `.exhaustLatest`, and
`.merged` are `OrderedPolicy` values. A future version may add merged streams
if a real use case appears.

### 5.3 Freshness and lifetime

A future query layer should support:

- stale rules based on age, network return, or app focus;
- tag-based invalidation across keyed families;
- a stream that yields a disk value, then a network value;
- separate clocks for freshness and memory retention.

Node lifetime depends on node kind:

- **Manual:** `.context` by default. Releasing a source would reset it on the
  next read. Ephemeral state may opt into
  `.whileObserved(resetToInitial: true)`.
- **Sync derived:** `.whileObserved(grace:)` by default. Cog can recompute it.
- **Async:** `.whileObserved(grace:)` by default. Release cancels work,
  advances its generation, and blocks late results from a new slot.
- **Query:** explicit `.cache(...)` policy with separate freshness and
  retention rules.
- **UI boundary:** pinned to the context in v1 because SwiftUI exposes no
  reliable observer-removal hook. Reactions and exported streams have exact
  lease tokens and may release normally.

Public lifetime terms are `context`, `whileObserved(grace:)`, and `cache(...)`.
`keepAlive` is only sugar for `.context`. If UI-pinned keyed growth becomes a
measured problem, an optional `DynamicProperty` can own an exact view lease.

### 5.4 Where the Rx operators went

See [rx.md](./rx.md). It maps Rx behavior to dynamic dependencies, async
policies, and `.stream`, while keeping ordered event history outside the state
graph.

---

## 6. Side effects, worked

See [effects.md](./effects.md) for reactions, effect groups, view lifetime,
testing, background work, and reconciler rules.

---

## 7. What the SwiftUI boundary must handle

- **Reads in escaping closures are not tracked.** A `Button` action or
  `Task {}` body is outside the view's tracked read. Debug builds should warn
  when a tracked `get` has no consumer, like Perception does.
- **View-owned model lifetime can be unstable.** Cog state lives in a context,
  not an `@Observable` object recreated with the view. Screen state uses an
  explicitly owned child context.
- **A collection is one observed property.** Use `CogBox` for per-key nodes. A
  future `ForEach` helper can combine a keys cog with per-key value cogs.
- **UI liveness is hidden.** Once a node gets a registrar boundary, pin it to
  the context in v1. Never guess UI liveness from graph subscribers.
- **MainActor values need not be `Sendable`.** Cog may hold values such as a
  `UIImage` or actor-bound service without extra wrappers. Handles should be
  documented, and later marked with `~Sendable`, as MainActor-only.
- **Build settings must not change behavior.** Test with default MainActor
  isolation on and off, and `NonisolatedNonsendingByDefault` on and off. Public
  declarations state isolation instead of relying on package defaults.

---

## 8. Interop and migration

- **Inputs from external `@Observable` objects:** `c.track(model, \.name)` or
  a closure form links outside state into the graph. On iOS 26, use
  `Observations`. On older systems, re-arm `withObservationTracking` and
  document its small race. Swift 6.4 can upgrade the shim to continuous
  tracking.
- **Exports:** `cogs.values(of:buffering:)` is a current-value-first multicast
  `AsyncSequence`. The default `.newest(1)` keeps memory bounded and never
  blocks a synchronous commit. A slow reader may skip turns, but every value
  it gets is settled. Offer `.oldest(n)` and `.unbounded` for explicit needs.
  Each subscriber owns a graph lease. Exact turn history belongs in the fixed
  debug log, not the default state stream.
- **UIKit and AppKit:** registrar-backed nodes work with their automatic
  tracking on supported OS versions. The same boundary serves all Apple UI
  frameworks.

Combine bridging is not a goal. `AsyncSequence` is the export surface.

---

## 9. Availability strategy

| Floor | Benefit | Cost |
| --- | --- | --- |
| **iOS 17 with Swift 6.2 tools** | Recommended. Full Cog graph and Observation boundary. | Cog must re-arm old tracking APIs and use `OSAllocatedUnfairLock` for a few cross-isolation helpers. |
| iOS 18 | Native `Mutex` and `Atomic`. | Small gain at Cog's edges. |
| iOS 26 | `Observations`, `Task.immediate`, newer UIKit tracking. | Excludes much of the current install base. |
| Swift 6.4 and its newer OS | Continuous tracking, cancellation shields, newer isolation tools. | Future shim target. |

The core graph does not need the high floors. New APIs improve only interop
edges. The package should also avoid required macros. Top-level lets and
closures are enough; any naming or projection macro must remain optional.

---

## 10. Decision record

Use the three principles to judge new choices: does the common path stay easy
to understand, can every read still be proven correct, and does measurement
show less runtime work?

### Settled

| Question | Decision |
| --- | --- |
| Who may write? | `fileprivate` plus `.readOnly` controls source names; a writer turn ID controls when writes are valid (§3.2, §4). |
| Op, transaction, or turn? | One named `commit`; ops are ordinary methods (§3.2). |
| Keyed and keyless API? | Boxes make refs; keyless cogs are pre-bound refs. Physical layout waits for benchmarks (§3.1; perf §4, §9). |
| Identity and names? | Descriptor `ObjectIdentifier` for process identity; explicit name or `fileID:line` for people (§2.3). |
| Static or dynamic dependencies? | Dynamic, captured on each run (§2.4). |
| Cycles and selector errors? | Show the keyed computing path and fail. Sync selectors do not throw in v1 (§2.4). |
| Consistent updates? | Lazy pull for reads; settle hot roots before push notices (§2.2, §3.2). |
| Key flow? | Normal lexical capture in a `CogBox` closure (§3.1). |
| Async value shape? | `CogPhase` with previous value and a `.latest` projection (§5.1). |
| Async dependency tracking? | A sync selector returns `Work`; no reads cross `await` (§5.1). |
| Default async policy? | `.latest` (§5.2). |
| Exhaust for derived state? | `.exhaustLatest` catches up once; true drop belongs to ops (§5.2). |
| Rx operators and temporary edges? | Dynamic links, async policies, and `.stream`; every edge is recaptured (§5.4). |
| Effect lifecycle? | Explicit `install(in:)` returns an idempotent final-class `EffectGroup` (§6.2–§6.3). |
| Writes from reactions? | Queue a new turn after the current flush; never re-enter. A debug quiescence guard reports loops (§6.4). |
| Accumulating versus flushing? | Nested commits join while accumulating and queue while flushing (§3.2). |
| Streams with async policies? | `.stream` is `.latest`-only and the type system enforces it (§5.2). |
| Node disposal? | Per-kind `context`, `whileObserved`, or `cache`; never infer UI liveness from graph edges (§5.3). |
| Global and local state? | Root and child `Cogtext`s supplied through the environment (§2.3). |

### Still open

1. **Read spelling:** `cogs.get(ref)`, `cogs[ref]`, or callable refs. Current
   lean: keep `get` because a tracked read creates an edge. Try all three in
   the weather spike.
2. **How much `Op` support ships in v1:** plain methods are enough to start.
   `.live` and `.latestFailure` call tracking need a separate design.
3. **Deferred reactions:** synchronous ordered flush and the write-back queue
   are settled. An optional next-tick `.deferred` mode may or may not earn its
   complexity.
4. **Cross-context reads:** a child may be able to read a longer-lived parent,
   but the lifetime rule is not designed.
5. **Debug history UI:** the bounded log records ops, writes, recomputations,
   and notices. Labels are settled. Its display may be `os_log`, an in-app
   inspector, or another developer tool.
6. **Dart and Flutter:** decide later whether a proven Swift model should feed
   descriptor, lazy-pull, and lexical-key choices back into Dart.
7. **Persistence helpers:** durable state writes the store first and its cog
   second (§6.7). It remains open whether this needs `PersistedCog` sugar or
   stays an op pattern, and when GRDB observation should replace seeding.

---

## 11. Spike plan

1. Build the simple correctness version: class nodes, `AnyHashable` refs,
   writer turn IDs, cycle paths, equality checks, hot-root flush, reactions,
   and per-kind lifetimes. Test diamonds, changing dependencies, conditional
   cycles, escaped writers, and reaction write-back.
2. Add registrar-backed nodes and a small SwiftUI weather app. Verify per-ZIP
   updates, UI pinning, and equality-gated derived notices. Also test UIKit on
   an iOS 26 simulator.
3. Port `js-reactivity-benchmark`. Compare inline `AnyHashable`, interned key
   tokens, and generic keyed refs, including keyed diamonds.
4. Read swift-state-graph before freezing public names. Credit prior art and
   compare tracked reads with capture lists.
5. Build the data-oriented core described in perf §3 behind the same tests.
   Measure it against the simple build, swift-state-graph, and raw
   `@Observable`.
6. Add async cogs: `.run` first, then `.exhaustLatest`, safe release,
   `.stream`, bounded exports, and finally query caching.

The earlier plan to split §5.4 and §6 into companion files was completed on
August 6, 2026.

---

## Appendix A: feature availability

| Feature | Swift | OS runtime |
| --- | --- | --- |
| `@Observable`, registrar, `withObservationTracking` (SE-0395) | 5.9 | iOS 17 / macOS 14 |
| SwiftUI property tracking and `@Bindable` | 5.9 | iOS 17 |
| `Mutex`, `Atomic` (SE-0433, SE-0410) | 6.0 | iOS 18 / macOS 15 |
| `sending`, `@isolated(any)`, region isolation (SE-0430, SE-0431, SE-0414) | 6.0 | Compile-time |
| Isolated deinit (SE-0371) | 6.1 | About iOS 18.4 |
| Default MainActor isolation, caller-isolated async, `@concurrent`, task names (SE-0466, SE-0461, SE-0469) | 6.2 | Compile-time / 6.2 runtime |
| `Observations`, `Task.immediate` (SE-0475, SE-0472) | 6.2 | iOS 26; not back-deployed |
| UIKit/AppKit automatic tracking and `updateProperties()` | — | iOS 26; opt-in from iOS 18 |
| `weak let` (SE-0481) | 6.3 | Compile-time |
| Continuous tracking, async `defer`, cancellation shields, `~Sendable` (SE-0506, SE-0493, SE-0504, SE-0518) | 6.4 | Newer “OS 27” family |

## Appendix B: sources and prior art

Platform:
[SE-0395 Observation](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0395-observability.md) ·
[SE-0475 Observations](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0475-observed.md) ·
[SE-0506 advanced tracking](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0506-advanced-observation-tracking.md) ·
[Observation source](https://github.com/swiftlang/swift/tree/main/stdlib/public/Observation) ·
[SE-0466 default isolation](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0466-control-default-actor-isolation.md) ·
[SE-0461 async isolation](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md) ·
[WWDC25: Embracing Swift concurrency](https://developer.apple.com/videos/play/wwdc2025/268/) ·
[Swift 6.2 release](https://www.swift.org/blog/swift-6.2-released/) ·
[Donny Wals on Swift 6.2 concurrency](https://www.donnywals.com/exploring-concurrency-changes-in-swift-6-2/) ·
[Jared Sinclair on Observation](https://jaredsinclair.com/2025/09/10/observation.html) ·
[Mastering Observation](https://fatbobman.com/en/posts/mastering-observation/) ·
[Observations limits](https://mjtsai.com/blog/2025/10/31/swift-6-2-observations/)

Swift ecosystem:
[swift-state-graph](https://github.com/VergeGroup/swift-state-graph) ·
[swiftui-atom-properties](https://github.com/ra1028/swiftui-atom-properties) ·
[swift-sharing](https://github.com/pointfreeco/swift-sharing) ·
[Perception](https://www.pointfree.co/blog/posts/180-perception-2-0-an-updated-back-port-of-swift-s-observation-framework) ·
[shareup/Signals](https://github.com/shareup/Signals) ·
[Relay `@Memoized`](https://github.com/NSFatalError/Relay) ·
[swift-operation](https://github.com/mhayes853/swift-operation) ·
[swift-async-algorithms](https://github.com/apple/swift-async-algorithms) ·
[TCA 2.0 preview](https://www.pointfree.co/blog/posts/200-the-point-free-way-tca-2-0-sneak-peek-a-giveaway-q-a-and-more)

Graph algorithms:
[Reactively](https://github.com/milomg/reactively/blob/main/Reactive-algorithms.md) ·
[alien-signals](https://github.com/stackblitz/alien-signals) ·
[preact Signal Boosting](https://preactjs.com/blog/signal-boosting/) ·
[TC39 Signals](https://github.com/tc39/proposal-signals) ·
[js-reactivity-benchmark](https://github.com/milomg/js-reactivity-benchmark)

## Appendix C: full off-main trade-off

**A dedicated graph actor** cannot serve synchronous SwiftUI reads. The app
would need a MainActor mirror, which becomes a snapshot design. A turn that
spans `await` can also interleave because Swift actors are re-entrant and have
no non-reentrant mode.

**A locked graph** can run on any thread with one lock per context. Per-node
locks would make dynamic edges a deadlock problem. Even one lock does not make
a whole SwiftUI render atomic: the graph could commit between two view reads.
Fixing that would need version-pinned snapshots, but SwiftUI gives no render
start and end hooks. This design also makes every cross-thread value
`Sendable`.

**A background graph with immutable snapshots** gives coherent reads, but a
control such as `TextField` needs its write to be visible on the next immediate
read. A main → background → main trip can drop characters or move the cursor.
Keeping form state on main would create two state systems.

The useful escape hatch is per-context isolation. A future context could be
bound to another actor and link to a MainActor context through explicit async
edges. Each context would stay single-threaded and keep the same rules.

This keeps the cheap case cheap. Small selectors such as `temperature > 68`
stay on main. Only costly user work crosses an executor; graph bookkeeping does
not.

## Appendix D: ecosystem survey details

- Early Solid and preact ports were small and stopped before Observation.
  unixzii/swift-signal had about 55 stars and ended in 2024.
- swiftui-atom-properties, at about 338 stars, is the strongest Recoil-style
  prior art. It has keyed and async atoms, scopes, effects, and automatic
  release. Its parameterized `Hashable` keys inform `CogBox`, though its model
  is still view-centered and rooted in one store.
- swift-state-graph, at about 67 stars in this survey, is active and close in
  purpose. It uses generic class nodes, explicit dependency capture lists, and
  no named turn model.
- TCA's macros and feature structure set a useful upper limit on Cog's
  complexity. Reports of roughly 200 lines of setup and large macro build-time
  costs support an API that reads like values and methods.
- `AsyncSequence`, `share()`, and work on `flatMapLatest` are closing old
  stream gaps without requiring Combine, which has seen little change since
  about 2020.
- Existing Swift query projects have not produced a clear standard; the
  surveyed TanStack-style attempts total fewer than 500 stars. Useful ideas
  include predicate-based staleness, tag invalidation, and separate freshness
  and retention clocks. swift-sharing covers persistence keys but not that
  full query model.
- Common `@Observable` pain points match Cog's scope: uncached derived values,
  equal-set notices, weak cross-object propagation, whole-collection tracking,
  and view-owned lifetime mistakes.
- Reactively and alien-signals provide the push-pull graph model. alien-signals
  also publishes port-ready pseudocode and now underlies Vue 3.6.
- `.latest` replaces the Dart draft's proposed `.allAtOnceInOrder` default.
  Latest-wins is safer for UI state because an old request cannot overwrite a
  new one.

[^observation-mechanics]: `@Observable` rewrites stored properties into
    computed accessors. Getters call `access(keyPath:)`; setters call
    `withMutation(keyPath:)`. SwiftUI evaluates `body` in an observation scope
    and captures exactly the properties read. UIKit and AppKit use the same
    model on newer OS versions. The small shareup/Signals project proves that
    a hand-written `value` property can join this boundary.

[^tracking-storage]: Observation uses thread-local storage for its active
    tracker. Since Cog never leaves the MainActor during sync graph work, one
    actor-isolated stack or slot is enough. It is pushed and popped around
    node computations and reactions.
