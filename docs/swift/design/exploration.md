# Cog for Swift: core design

_August 9, 2026_

_See [README.md](../README.md) for the document map._

Cog is a fine-grained state library for SwiftUI: a change updates only the
derived values and views that used it. Cog uses Apple's Observation system at
the UI edge and its own dependency graph inside. This document covers the core
design; [rx.md](./rx.md) holds §5.4 and [effects.md](./effects.md) holds §6.

Swift fits Cog well. The MainActor gives the graph one safe execution lane,
Observation lets SwiftUI track individual values, and access control can
enforce write ownership. Cog adds what the platform lacks: cached derived
state, consistent updates, keyed boxes, named turns, and async policies.

Four principles judge the design:

1. **Feel simple:** normal use should look like ordinary Swift and require few
   concepts.
2. **Make every state read correct:** a read must see the latest committed
   sources after settling every dependency needed for that value.
3. **Minimize runtime overhead:** do no more computation, allocation, or UI
   work than the result needs.
4. **Keep state singular:** one running app has one authoritative `Cogtext`,
   and each mutable fact represented in Cog has one writable source in it.
   Scenes, screens, and features do not create state islands or mirror
   sources.

The first, second, and fourth constrain the third. An optimization must not
weaken read correctness, fragment state, or complicate the common API.

---

## 1. What the platform gives us, and what it doesn't

### 1.1 Observation is the UI boundary, not the graph

`@Observable` records which properties a view reads, so SwiftUI can update
that view when one changes. A Cog state joins this system by calling
`ObservationRegistrar.access` on reads and `withMutation` after real changes.
No view adapter is needed.[^observation-mechanics]

Observation does not provide Cog's inner graph:

| Cog needs                                | Observation provides                                                                            |
| ---------------------------------------- | ----------------------------------------------------------------------------------------------- |
| Cached derived values                    | Nothing; computed properties run on every read.                                                 |
| One consistent snapshot                  | Nothing below iOS 26; old callbacks start at `willSet`.                                         |
| Explicit turns                           | iOS 26 `Observations` batches between suspension points, but has no explicit transaction block. |
| Continuous tracking                      | One-shot tracking until Swift 6.4 and its newer OS runtime. Manual re-arming can miss changes.  |
| Equality checks                          | Nothing; setting an equal value still sends a notice.                                           |
| Keyed boxes, async values, write control | Nothing.                                                                                        |

Two platform rules shape Cog:

- Tracking sees only synchronous reads in the tracked scope. Reads in later
  closures or on another thread do not count. The synchronous `c.get` API
  makes this rule visible.
- The registrar is thread-safe, but observed storage is not. State still needs
  one owner.

### 1.2 The graph stays on the MainActor

New Swift app targets default to the MainActor, so UI state already runs on
one ordered executor. The graph is therefore **MainActor-confined** — not its
own actor and not lock-protected. A synchronous turn cannot interleave with
another turn. Async cogs and ops may do background work, then return results
to the MainActor.

Useful Swift tools: default MainActor isolation makes top-level cog
declarations natural; `nonisolated(nonsending)` keeps async work on the
caller's actor; `@concurrent` moves expensive work to the global executor;
`Task.immediate` (iOS 26) starts subscription work without a one-tick delay;
task names improve Instruments output; Swift 6.4 adds cancellation shields,
typed-throws tasks, and `~Sendable`.

An actor of Cog's own would be re-entrant at each `await`. A lock-based graph
would bring back torn UI reads and force every value to be `Sendable`. Moving
only expensive computation off main gives most of the benefit at far lower
cost (§2.5, Appendix C).

### 1.3 The ecosystem leaves room for Cog

No current Swift library combines this platform fit with all four principles
at Cog's intended scale. swift-state-graph caches derived values and supports
Observation, but uses capture-list dependencies and has no turn model.
swiftui-atom-properties has keyed and async atoms, scopes, effects, and
release rules, but centers the view layer on the older `ObservableObject`
model. TCA is powerful but far larger than Cog wants to be; Combine is largely
frozen while `AsyncSequence` and Observation advance; and no Swift library
owns keyed query caching, stale data, and invalidation.

Modern JavaScript signal systems agree on the core algorithm: writes push
cheap dirty flags, reads pull new values only when needed, and equal results
stop further work. Cog follows that push-pull model. Appendix B links the
research; Appendix D keeps the ecosystem notes.

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

Cog owns the inner graph; Observation is only the boundary. Using Observation
inside the graph would mean one-shot `willSet` callbacks (racy re-arming and
mid-change reads), chained callbacks that each update at a different time (the
“telephone problem”), and OS floors too high for continuous tracking. An owned
graph keeps the main feature set at iOS 17. New Observation APIs can still
link outside objects into Cog (§8), and Perception could back-deploy the UI
boundary to iOS 13 if ever needed.

### 2.2 Lazy reads keep state consistent

Terms used below:

- A **source** is writable state.
- A **derived cog** computes a value from other cogs.
- A **state** is one source or derived value in the app `Cogtext`, or in the
  one isolated context of a test or preview runtime.
- A **turn** is one outermost `commit` and the work it causes.
- A **hot root** has a live UI, reaction, or stream consumer. A cold state does
  not.

A “correct read” is a value derived from all source writes in the latest
completed turn. It does not mean outside data is always fresh: an async cog
may be pending or showing a previous value, but `CogPhase` makes that
explicit. During a commit, reads through its `Writer` instead see that turn's
staged source values, so read-modify-write stays correct.

Cog never recomputes the whole graph after a write. It marks possible changes,
then computes a derived cog when a consumer needs it. That read first updates
its parents, and equality checks stop work when a value stayed the same. The
reader gets one consistent result, never a half-finished wave.

At the end of a turn, Cog also serves push-based consumers: it commits
changed source values, marks downstream states dirty, settles the dirty hot
roots (cold branches stay lazy), notifies changed UI states and streams, and
runs changed reactions in registration order. §3.2 gives the normative flush
order.

Each outer `commit` is its own turn, even when two commits run in the same
event handler, so every change has a name and a history record. A slow state
stream may still coalesce values through its buffer policy (§8).

The commit point is structural. Writes require the `Writer` passed into
`commit`; when the outer body exits, Cog flushes the turn. Nested commits join
it. A writer carries a turn ID, so saving it and calling it later fails.

### 2.3 Descriptors name state; `Cogtext` stores it

A top-level declaration is a light descriptor, not a live global value. The
app's one `Cogtext` stores the state for each descriptor and optional key; a
test or preview runtime has its own isolated context. This split gives Cog
keyed boxes (a box plus a key finds one state), singular state (every feature
resolves through one graph), clean tests (no process-global reset), and one
history owner for every turn and recomputation.

Production code must not create child contexts. Truly view-local state stays
in SwiftUI `@State`. Cog-backed screen state lives in the app graph, keyed by
a screen identity when needed, and resets through an explicit op. One mutable
domain fact gets one manual source; another feature may read it or derive a
new shape, but must not mirror it into a second `ManualCog`.

Production construction is guarded: the plain `Cogtext` initializer is
`package`, so application code cannot name it at all. The app's bootstrap
calls `Cogtext.bootstrapApp()` once, at launch; a second call fails fast in
debug and release builds. The `CogTesting` product adds
`Cogtext.forTesting()`, which hands a test or preview runtime a fresh isolated
context as often as it asks and never registers as the production context.

The two spellings differ in grammar on purpose. Creating the app's context is
a once-per-process act, so it reads as a verb; creating a test context is
ordinary value creation, so it reads as a noun phrase. Neither is spelled
`install`, which §6.3 gives to effects.

`bootstrapApp()`'s return value is the production ownership handle. The app
keeps it and passes it into effects, services, and every scene; views receive
that same object through the `\.cogs` environment value. Ops remain ordinary
instance methods on `Cogtext`. There is deliberately no ambient
`Cogtext.app`: code outside an injection chain receives the context at its
composition boundary, which keeps the same feature usable with an isolated
testing context and avoids a separate missing-bootstrap trap contract.

Tests whose subject is the production install use a synchronous MainActor
`CogTesting` fixture that calls the real bootstrap, passes its result into the
body, and removes the process-global registration in `defer`. The fixture
cannot be `async`, because suspension would let parallel tests observe or
collide with the temporary install. Narrow testing-only predicates may inspect
whether a context is the installed object; they do not expose graph storage or
add ambient lookup to the shipping product.

Descriptors are internal final classes whose `ObjectIdentifier` gives stable
process identity. The public `Cog<T>` and `ManualCog<T>` types are lightweight
value references that carry a descriptor and, when keyed, a key; their boxes
are lightweight declaration values. A keyless declaration such as
`Cog<Bool> { ... }` allocates one descriptor and returns a value reference
already bound to it. `box[key]` builds a value reference without allocating a
new descriptor, which is what lets the perf plan call value-reference creation
allocation-free. Human labels use an explicit `name:` or the captured
`fileID:line`; users never see the object identifier. A future optional macro
could infer names without changing identity.

Reads go through the app context — `c.get(valueReference)` inside a selector,
`cogs.get(valueReference)` outside. The context tracks dependencies and records one
history for the whole app.

The explicit `get` is deliberate at both boundaries. It says that a read adds
an edge, keeps the one-shot escape hatch visibly different as `read`, and
leaves subscript syntax to a `Writer` whose getter and setter use the active
turn. A callable value reference would put graph work on what is otherwise an
inert name and still need the context as an argument.

### 2.4 Dependencies are captured on every run

Dependencies are exactly the cogs read with `c.get` during the last run.
Conditions and early returns are valid; every edge must be read again on the
next run to stay attached. The runtime places the current consumer in a
MainActor tracking slot while a selector or reaction runs, and each `get`
links producer to consumer.[^tracking-storage]

Rules:

- Reuse dependency edges across runs; remove any edge not read again. The
  physical edge layout is benchmark-gated (perf §3.3).
- Track CLEAN, CHECK, and DIRTY state plus version numbers to skip work when
  no parent value really changed.
- Compare old and new values after every computation: use `Equatable` when
  available, allow a custom `equals:`, and treat non-equatable values as
  changed.
- Mark a state while its selector runs. Reading any marked state is a cycle:
  fail in every build and show the full descriptor-and-key path. An internal
  seam lets tests inspect diagnostics without crashing the test process.
- Synchronous selectors do not throw in v1. Use `Result` for fallible sync
  domain work and `CogPhase` for async failures.
- `c.read` returns a cog's current value without creating an edge — the
  untracked escape hatch for a value the selector uses but must not follow, as
  in `withLatestFrom` (§5.4). Untracked reads still settle: `c.read` and the
  one-shot `cogs.read` compute a dirty value before returning it, so skipping
  the edge never means seeing a stale value. Keep it rare and loud; an
  untracked read that should have been tracked is a stale-value bug.
- `c.curr` exposes the cog's own prior value so a selector may keep or fold
  it.

The benchmark port must test diamonds, deep graphs, broad graphs, changing
dependencies, and cycles.

### 2.5 Why the graph is not off-main

Three off-main designs are possible, but none fits the UI boundary:

| Design                          | Main problem                                                                                                                |
| ------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| Graph on another actor          | SwiftUI reads are synchronous and cannot `await`; actor reentrancy can also interleave turns.                               |
| Locked graph on any thread      | A view can read two cogs from different turns, and all values become `Sendable`.                                            |
| Background graph with snapshots | Snapshots are coherent, but text fields need immediate write-then-read behavior. Local UI state would need a second system. |

Graph bookkeeping is cheap; user code inside a selector is the likely cost.
Keep small derived values on main and use `@concurrent` work in an `AsyncCog`
for expensive computation. Network, database, and sensor producers can work
elsewhere and enter through an op. A server-side runtime would still get one
single-executor context: off-main work is computation, not a second state
graph, and returns through explicit async results or ops. Appendix C has the
full trade-off analysis.

---

## 3. API sketch

The examples assume a Swift 6.2 module with default MainActor isolation;
library declarations still state isolation explicitly (§7). The common path
uses plain declarations, reads, methods, and bindings so the graph machinery
does not dominate application code.

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

| Declare           | Example                                          | Read                                           |
| ----------------- | ------------------------------------------------ | ---------------------------------------------- |
| One derived value | `Cog<Bool> { ... }`                              | `c.get(valueReference)` → `Bool`               |
| A derived box     | `CogBox<Bool, ZipCode> { ... }`                  | `c.get(box[zip])`                              |
| One source        | `ManualCog<ZipCode?>(nil)`                       | Read normally; write `w[valueReference] = zip` |
| A source box      | `ManualCogBox<Weather?, ZipCode>(nil)`           | `w[box[zip]] = report`                         |
| One async value   | `AsyncCog<Forecast>(.latest) { ... }`            | `CogPhase<Forecast>`                           |
| An async box      | `AsyncCogBox<Weather, ZipCode>(.latest) { ... }` | Full phase or `.latest` value (§5.1)           |

Four rules keep these forms consistent:

1. **Value references are the only inputs to runtime APIs.** `Cog<T>` is readable;
   `ManualCog<T>` is readable and writable. A value reference is a value pairing an
   internal final-class descriptor with an optional key; identity is
   descriptor plus key (§2.3).
2. **Boxes create value references.** `box[key]` returns a value reference. A keyless declaration is
   the same system already bound to its only state.
3. **Production kind does not change the read type.** Manual, derived, and
   async describe how a value is made. Async value references are ordinary
   `Cog<CogPhase<T>>` value references with a `.latest` projection.
4. **Frequent call sites stay short.** `get`, `commit`, `w[...]`, and
   `box[key]` are common. Longer names such as `ManualCogBox` appear only at
   declarations.

The semantic shape is settled; the physical value-reference layout is not. The first build
uses inline `AnyHashable?`. Benchmarks will compare it with interned key
tokens and generic keyed value references, and the public value-reference type
stays resilient, not `@frozen`, until data chooses a winner (perf §4 and §9).

Keys pass through normal lexical capture, as `zip` does above — there is no
hidden key flow. States appear lazily per descriptor and key. A manual box's
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
  `Cogtext` method that calls `commit`; pass a custom name only when needed.
- Access control decides which source value references the method may name (§4).

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
4. Notify changed boundary states and offer changed stream values to each
   subscriber's buffer.
5. Run changed reactions in registration order and capture their new
   dependencies.
6. Return to idle, or drain queued write-back turns in FIFO order.

First-class `Op` values with call status may come later. Plain methods already
give write control and turn names, so v1 does not need them.

### 3.3 Reactions

```swift
let token = cogs.run { c in
    if c.get(isNiceOutsideHere) {
        notifier.alert("It is nice outside!")
    }
}
```

A reaction runs once when registered to record dependencies, and again after a
turn changes one of them, always against settled state. Outside a flush, that
initial run happens before `cogs.run` returns. During a flush, registration
does not re-enter the reaction that made it: the initial run joins the tail of
that flush's reaction queue in registration order, after reactions already
scheduled for the turn and before queued write-back turns begin. The returned
final-class token cancels safely more than once and also cancels on deinit;
copies refer to the same registration. §6 covers effect ownership, timers,
registration, and reaction write-back.

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

`cogs.get` reads through the state's registrar, so SwiftUI tracks that exact
descriptor and key and updates the view only when one of those values really
changes. There is no special view, hook, or property wrapper; the app injects
its one `Cogtext` above every scene through the environment. SwiftUI does not
tell Cog when it stops watching a registrar object, so any state that reaches
this UI boundary stays pinned to the app context (§5.3).

Sources are `fileprivate`, so views cannot create raw writable bindings. The
state file exports a domain binding:

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

`binding(for:)` pairs a tracked read with a named commit, so the state file
still lists every write path. For a one-time untracked read, use
`cogs.read(...)`.

---

## 4. Write ownership

Swift access control replaces the custom lints proposed for Dart:

- Declare writable sources `fileprivate`, or `private` inside a type. Only
  that file or type can name them.
- Expose `.readOnly` value references or derived cogs.
- Put ops, bindings, and test seams beside the sources they may write.

Callers can use `try await cogs.checkWeather(zip)` but cannot reach
`weatherReportSource`. A review finds every possible write by searching one
file's commit blocks.

`@testable import` cannot see `fileprivate` sources, so the owning file must
publish narrow debug-only seed or stub methods; §6.6 shows quiet `seed`
helpers and loud commit helpers. Making all sources `internal` would weaken
the rule from one file to one module.

---

## 5. Async cogs

### 5.1 Values and work

Async state uses one phase type and keeps the last good value:

```swift
enum Previous<Value> {
    case none
    case some(Value)
}

enum CogPhase<Value> {
    case pending(previous: Previous<Value>)
    case success(Value)
    case failure(any Error, previous: Previous<Value>)

    var latestValue: Value? { ... }
    var isLoading: Bool { ... }
}
```

There is no public `initial` phase. Before first use, an async state does not
exist in the context and has no phase to observe. Its first read creates the
state, starts its work, publishes `.pending(previous: .none)` as a turn, and
returns that pending phase. This keeps the first observable state honest: work
has begun and no value has completed yet.

`Previous` keeps “no previous value” distinct from “the previous value was
nil.” With a plain `Value?`, that distinction would hide in a nested optional
whenever `Value` is itself optional, and a bare `nil` would be ambiguous at
use sites. `latestValue` still returns `Value?`; its outer layer answers “is
there a latest value at all.” There is no failure type parameter in v1; typed
throws may add one once the required Swift and OS versions are practical.

An async selector is synchronous and tracked. It reads dependencies, then
returns a description of async work:

```swift
let fetchedWeather = AsyncCogBox<Weather, ZipCode>(.latest) { c, zip in
    let service = c.get(weatherService)
    return .run { try await service.weather(for: zip) }
}
```

§3.1 modeled `weatherReport` as a manual box that the `checkWeather` op fills;
`fetchedWeather` is the async alternative, where the fetch itself is derived
state. A real app picks one shape per fact — the two appear side by side here
only to compare them.

`Work` has two forms: `.run { ... }` returns one value, committed as one turn;
`.stream(sequence)` commits each sequence element as its own turn. The split
prevents hidden async tracking bugs: every `c.get` happens before the work
starts, so no read can silently stop tracking after an `await`. Changing a
dependency reruns the selector and creates new work; the policy in §5.2
decides what happens to the old work.

Read either the full phase or its last good value:

```swift
c.get(fetchedWeather[zip])
c.get(fetchedWeather.latest[zip])
```

The `.latest` projection lets downstream code read a manual `Weather?` and an
async weather value in the same shape. Use `AsyncCog` for async derived state
and an op for an imperative action; a forced refresh can be an op such as
`cogs.refresh(fetchedWeather[zip])`.

### 5.2 Scheduling policies

| Policy              | Behavior                                                   | Common stream name           |
| ------------------- | ---------------------------------------------------------- | ---------------------------- |
| `.latest` (default) | Cancel old work; only the newest generation may commit.    | `switchMap`                  |
| `.queue`            | Run requests in order.                                     | `concatMap`                  |
| `.exhaustLatest`    | Finish current work, coalesce changes, then catch up once. | exhaust with latest catch-up |
| `.merged`           | Allow overlapping runs; each result is its own turn.       | `merge` / `flatMap`          |

Cancellation alone is not enough: old work may finish before it notices
cancellation, so every run gets a generation number, and the MainActor commits
a result only if that generation is still current.

Each visible pending, success, or failure state is a turn. Replacing cancelled
work does not publish a failure; a future explicit cancel API must define the
phase it writes.

True exhaust behavior drops events while busy. A derived value cannot forget
dependency changes and still represent current state, so `.exhaustLatest`
catches up once. True exhaust belongs to imperative ops.

Work stays on the MainActor by default and suspends at `await`. Expensive
`Sendable` work can opt into `@concurrent`. Internal tasks use descriptor
names and keys for Instruments.

**Streams allow only `.latest`.** A queued infinite stream blocks the queue
forever; an exhausted infinite stream never catches up. The type system
enforces this:

```swift
init(_ policy: LatestPolicy,
     _ selector: (C) -> Work<Value>)       // .run or .stream

init(_ policy: OrderedPolicy,
     _ selector: (C) -> RunWork<Value>)    // .run only
```

`.latest` is the only `LatestPolicy`; `.queue`, `.exhaustLatest`, and
`.merged` are `OrderedPolicy` values. Merged streams may come later if a real
use case appears.

### 5.3 Freshness and lifetime

A future query layer should support stale rules based on age, network return,
or app focus; tag-based invalidation across keyed boxes; a stream that yields
a disk value, then a network value; and separate clocks for freshness and
memory retention.

State lifetime depends on state kind:

- **Manual:** `.app` by default, because releasing a source would reset it on
  the next read. Ephemeral state may opt into
  `.whileObserved(resetToInitial: true)`.
- **Sync derived:** `.whileObserved(grace:)` by default. Cog can recompute it.
- **Async:** `.whileObserved(grace:)` by default. Release cancels work,
  advances its generation, and blocks late results from a new slot.
- **Query:** explicit `.cache(...)` policy with separate freshness and
  retention rules.
- **UI boundary:** pinned to the app context in v1 because SwiftUI exposes no
  reliable observer-removal hook. Reactions and exported streams have exact
  lease tokens and may release normally.

Public lifetime terms are `app`, `whileObserved(grace:)`, and `cache(...)`;
`keepAlive` is only sugar for `.app`. If UI-pinned keyed growth becomes a
measured problem, an optional `DynamicProperty` can own an exact view lease.

A declaration that selects `whileObserved` without an explicit grace uses its
context's default. Production contexts use 30 seconds: long enough to absorb
ordinary UI reconstruction without making abandoned derived caches
effectively app-lifetime. `CogTesting` accepts a context override so lifetime
tests can inject both a controllable clock and an explicit duration; no test
waits for the production interval or wall-clock time.

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
- **View-owned model lifetime can be unstable.** Cog state lives in the app
  context, not an `@Observable` object recreated with the view. Truly local UI
  state uses `@State`; shared screen state uses keyed app cogs and explicit
  reset ops.
- **A collection is one observed property.** Use `CogBox` for per-key states. A
  future `ForEach` helper can combine a keys cog with per-key value cogs.
- **UI liveness is hidden.** Once a state gets a registrar boundary, pin it to
  the app context in v1. Never guess UI liveness from graph subscribers.
- **MainActor values need not be `Sendable`.** Cog may hold values such as a
  `UIImage` or actor-bound service without wrappers. Document such handles as
  MainActor-only, and later mark them `~Sendable`.
- **Build settings must not change behavior.** Test with default MainActor
  isolation on and off, and `NonisolatedNonsendingByDefault` on and off.
  Public declarations state isolation instead of relying on package defaults.

---

## 8. Interop and migration

- **Inputs from external `@Observable` objects:** `c.track(model, \.name)` or
  a closure form links outside state into the graph. The guarantee is at an
  observation propagation boundary: after an observed mutation propagates, a
  dependent cog returns the newest post-mutation value, never the pre-write
  value. Several mutations within one boundary may coalesce. On iOS 26,
  `Observations` supplies those boundaries at suspension points. On older
  systems, Cog defers invalidation until the setter has completed, then re-arms
  `withObservationTracking`; an internal test seam acknowledges that re-arm,
  and a mutation made afterward has the same post-mutation guarantee. The
  one-shot API still has a small disarmed window in which another mutation may
  be missed, and Cog documents that limitation rather than promising
  continuous tracking. Swift 6.4 can upgrade the shim to continuous tracking.
- **Exports:** `cogs.values(of:buffering:)` is a current-value-first multicast
  `AsyncSequence`. The default `.newest(1)` keeps memory bounded and never
  blocks a synchronous commit; a slow reader may skip turns, but every value
  it gets is settled. `.oldest(n)` keeps the first n undelivered values in
  order and drops newer ones while its buffer is full; `.unbounded` delivers
  every settled value. Both cover explicit needs, and no policy makes a commit
  wait on a reader. Each subscriber owns a graph lease. Exact turn history belongs in the fixed debug
  log, not the default state stream.
- **UIKit and AppKit:** registrar-backed states work with their automatic
  tracking on supported OS versions. The same boundary serves all Apple UI
  frameworks.

Combine bridging is not a goal. `AsyncSequence` is the export surface.

---

## 9. Availability strategy

| Floor                           | Benefit                                                           | Cost                                                                                                 |
| ------------------------------- | ----------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| **iOS 17 with Swift 6.2 tools** | Recommended. Full Cog graph and Observation boundary.             | Cog must re-arm old tracking APIs and use `OSAllocatedUnfairLock` for a few cross-isolation helpers. |
| iOS 18                          | Native `Mutex` and `Atomic`.                                      | Small gain at Cog's edges.                                                                           |
| iOS 26                          | `Observations`, `Task.immediate`, newer UIKit tracking.           | Excludes much of the current install base.                                                           |
| Swift 6.4 and its newer OS      | Continuous tracking, cancellation shields, newer isolation tools. | Future shim target.                                                                                  |

The core graph does not need the high floors; new APIs improve only interop
edges. The package should also avoid required macros — top-level lets and
closures are enough, and any naming or projection macro must remain optional.

---

## 10. Decision record

Use the four principles to judge new choices: does the common path stay easy
to understand, can every read still be proven correct, does state stay
singular, and does measurement show less runtime work?

### Settled

| Question                          | Decision                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| --------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Who may write?                    | `fileprivate` plus `.readOnly` controls source names; a writer turn ID controls when writes are valid (§3.2, §4).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| Op, transaction, or turn?         | One named `commit`; ops are ordinary methods (§3.2).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| Keyed and keyless API?            | Boxes make value references; keyless cogs are pre-bound value references. Physical layout waits for benchmarks (§3.1; perf §4, §9).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| Identity and names?               | Descriptor `ObjectIdentifier` for process identity; explicit name or `fileID:line` for people. Public `Cog` and `ManualCog` types are value references over internal final-class descriptors (§2.3, §3.1).                                                                                                                                                                                                                                                                                                                                                                                                                              |
| Static or dynamic dependencies?   | Dynamic, captured on each run (§2.4).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| Cycles and selector errors?       | Show the keyed computing path and fail. Sync selectors do not throw in v1 (§2.4).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| Writes from derived computation?  | A derived computation is read-only from selector entry through dependency reconciliation, custom equality, and result publication. Any commit attempted in that region fails immediately in every build, before the commit body runs or that attempt mutates graph state, and names the derived cog/key plus the attempted turn. Invoke the op outside derived computation, from event handling or a reaction (§2.4, §3.2).                                                                                                                                                                                                             |
| Consistent updates?               | Lazy pull for reads; settle hot roots before push notices (§2.2, §3.2).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| Key flow?                         | Normal lexical capture in a `CogBox` closure (§3.1).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| Async value shape?                | `CogPhase` begins publicly at `pending`—there is no observable `initial` phase—and uses an explicit `Previous` case to distinguish “no previous value” from “previous value was nil,” plus a `.latest` projection (§5.1).                                                                                                                                                                                                                                                                                                                                                                                                               |
| Async dependency tracking?        | A sync selector returns `Work`; no reads cross `await` (§5.1).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| Default async policy?             | `.latest` (§5.2).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| Exhaust for derived state?        | `.exhaustLatest` catches up once; true drop belongs to ops (§5.2).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| Rx operators and temporary edges? | Dynamic links, async policies, and `.stream`; every edge is recaptured (§5.4).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| Effect lifecycle?                 | Explicit `install(in:)` returns an idempotent final-class `EffectGroup`. Cancellation is terminal and shared across copies: adding a reaction token afterward synchronously cancels it before `add` returns without retaining it; a task requested afterward is already cancelled when `task` returns. Neither operation reopens the group (§6.2–§6.3).                                                                                                                                                                                                                                                                                 |
| Writes from reactions?            | Queue a new turn after the current flush; never re-enter. A debug turn-chain guard reports long causal chains through a testable diagnostic seam (§6.4).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| Reaction registration in a flush? | Do not run the new reaction reentrantly. Append its initial tracking run to the tail of the current flush's reaction queue, in registration order: after reactions already scheduled for that turn and before queued write-back turns begin (§3.3).                                                                                                                                                                                                                                                                                                                                                                                     |
| Test seeding?                     | Debug-only `seed` stages a value and pushes dirty flags like a write, but records no turn, sends no notices, and runs no reactions (§6.6).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| Accumulating versus flushing?     | Nested commits join while accumulating and queue while flushing (§3.2).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| Streams with async policies?      | `.stream` is `.latest`-only and the type system enforces it (§5.2).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| State disposal?                   | Per-kind `app`, `whileObserved`, or `cache`; never infer UI liveness from graph edges. A `whileObserved` declaration without an explicit grace uses its context's 30-second production default, and `CogTesting` can override that context default alongside its injected clock (§5.3).                                                                                                                                                                                                                                                                                                                                                 |
| State graph count?                | One app-wide `Cogtext`. Tests and previews are separate runtimes with one isolated context (§2.3).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| Untracked reads?                  | `c.read` and one-shot `cogs.read` skip the dependency edge but still settle the value they return; an untracked read is never stale (§2.4).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| UI read spelling?                 | `cogs.get(valueReference)`. Tracking belongs to the context, the spelling matches selector reads through `Reader.get`, it contrasts with one-shot `cogs.read`, and it leaves subscripts to staged `Writer` reads and writes (§2.3, §3.2, §3.4).                                                                                                                                                                                                                                                                                                                                                                                         |
| Export buffer overflow?           | `.newest(1)` may skip turns for a slow reader; `.oldest(n)` delivers the oldest n in order and drops newer while full; `.unbounded` delivers everything. Commits never wait on readers (§8).                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| External Observation tracking?    | After an observed mutation propagates, dependents see its newest post-mutation value; mutations may coalesce. The pre-iOS-26 one-shot shim internally acknowledges re-arming but retains a documented disarmed race (§8).                                                                                                                                                                                                                                                                                                                                                                                                               |
| Context construction?             | App bootstrap calls `Cogtext.bootstrapApp()` once; feature code cannot construct another context (§2.3).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| Bootstrap helper names?           | `Cogtext.bootstrapApp()`, vended by `Cog`, creates the one production context and fails fast on a second call; `Cogtext.forTesting()`, vended by `CogTesting`, returns a fresh isolated context as often as a test or preview asks. A `package` initializer leaves those two as the only ways in, and separating them by product rather than by an argument keeps the test factory out of a shipping app target (§2.3, §6.3, §6.6).                                                                                                                                                                                                     |
| Production context access?        | `bootstrapApp()` returns the ownership handle; the app passes it into effects, services, and scenes, and views receive it through `\.cogs`. Ops are `Cogtext` instance methods. There is no ambient `Cogtext.app`, so production and isolated tests use the same explicit composition boundaries (§2.3, §3.2, §3.4, §6.3).                                                                                                                                                                                                                                                                                                              |
| Production-install test fixture?  | `CogTesting` vends a synchronous MainActor `withBootstrappedApp` scope plus narrow install predicates. It calls the real bootstrap and removes the registration in `defer`; it is deliberately not async, so parallel tests cannot interleave through process-global install state (§2.3; impl scenarios constraint 3).                                                                                                                                                                                                                                                                                                                 |
| Testing posture?                  | Fully optimistic (every wait is a definite injected signal: clocks, continuations, acknowledgements), as fast and cheap as possible (host-first; simulators only at the device boundary; injected time everywhere, including `whileObserved` grace), and as implementation agnostic as possible (public API, then `CogTesting`, then debug history, then named diagnostic seams; the behavior suite passes unchanged across core swaps). Normative statement in impl/scenarios.md.                                                                                                                                                      |
| Trap spelling?                    | Fail-fast traps use `fatalError`, never `preconditionFailure`. The standard library drops `preconditionFailure`'s message under `-O`, so the process traps with no explanation and a promise of "a clear error … in release builds" (ONE-02, TURN-07, CYCLE-01, CYCLE-02) could not be kept. Measured on Apple Swift 6.3: under `-Onone` both spellings print; under `-O` only `fatalError` does, including under `-Ounchecked`. An exit test proving a trap asserts on the child process's standard error, not merely its exit status.                                                                                                 |
| Generic class `deinit`?           | Every generic class in the library writes an explicit `nonisolated deinit`. Under `.defaultIsolation(MainActor.self)` a _synthesized_ `deinit` on a generic class is main-actor-isolated, and Apple Swift 6.3.0 and 6.3.3 both crash the optimizer on it (SIGSEGV in `EarlyPerfInliner`) in release configuration only. Debug builds are unaffected, so only a release build catches a regression — `mise run test:release` is the guard, and it runs in CI. The rule is independently correct, since these deinits only release their own stored properties and the classes are never `Sendable`. Revisit when the toolchain fixes it. |
| Implementation execution?         | Dependency-aware half-day tasks, each typed as a decision, infrastructure slice, red-green behavior slice, gate, or single publication step. Every task names its dependencies and closing verification and ends green; representation changes integrate incrementally, and releases separate non-mutating preparation from publication. Normative statement in impl/tasks.md.                                                                                                                                                                                                                                                          |

### Still open

These numbers are stable identifiers that other documents cite. A settled item
keeps its slot and points at the table above instead of renumbering the rest.

1. **Read spelling:** settled on August 12, 2026 as
   `cogs.get(valueReference)`. See "UI read spelling?" above.
2. **How much `Op` support ships in v1:** plain methods are enough to start.
   `.live` and `.latestFailure` call tracking need a separate design.
3. **Deferred reactions:** synchronous ordered flush and the write-back queue
   are settled. An optional next-tick `.deferred` mode may or may not earn its
   complexity.
4. **App bootstrap:** settled on August 11, 2026 as `Cogtext.bootstrapApp()`
   and `Cogtext.forTesting()`, with explicit ownership/injection and the scoped
   `CogTesting` production-install fixture. See "Bootstrap helper names?",
   "Production context access?", and "Production-install test fixture?"
   above.
5. **Debug history UI:** the bounded log records ops, writes, recomputations,
   and notices. Labels are settled. Display may be `os_log`, an in-app
   inspector, or another developer tool.
6. **Dart and Flutter:** decide later whether a proven Swift model should feed
   descriptor, lazy-pull, and lexical-key choices back into Dart.
7. **Persistence helpers:** durable state writes the store first and its cog
   second (§6.7). Open whether this needs `PersistedCog` sugar or stays an op
   pattern, and when GRDB observation should replace seeding.
8. **Stream termination:** what a `.stream` cog's phase does when its
   sequence ends naturally — stay at the last success forever, or something
   observable.
9. **Stream failure:** whether a `.stream` sequence that throws publishes a
   failure phase. §5.2 defines only the replaced-cancelled case.
10. **`.queue` failure:** whether a failed queued run stops the queue or the
    next queued run still starts.
11. **Writes from a selector:** settled on August 12, 2026. A commit attempted
    anywhere in a derived computation fails immediately in every build before
    the commit body runs or that attempt mutates graph state. See "Writes from
    derived computation?" above.
12. **`EffectGroup.add` after cancel:** settled on August 12, 2026. The group
    stays terminal and synchronously cancels the incoming reaction token before
    `add` returns. See "Effect lifecycle?" above.
13. **Timing modifiers:** §5.4 points `debounce` and `throttle` at "a
    reaction modifier or async-cog option," but no design or milestone
    exists. Deferred backlog.
14. **Equal stream elements:** §5.2 commits each `.stream` element as its own
    turn, while §3.2 discards equal writes at flush. Decide which rule wins
    when a sequence yields consecutive equal elements.
15. **One-shot reads of cold async cogs:** untracked reads settle (§2.4), and
    an async cog's first read starts work and publishes a pending turn
    (§5.1). Define what a subscription-free `cogs.read` of a never-read
    async cog does — and, relatedly, what `cogs.refresh` of a never-read value reference
    does.
16. **Registration during a flush:** settled on August 11, 2026. The initial
    run joins the current flush's reaction tail without re-entry, after work
    already scheduled for the turn and before queued write-back turns. See
    "Reaction registration in a flush?" above.

---

## 11. Spike plan

1. Build the simple correctness version: class states, `AnyHashable` value references,
   writer turn IDs, cycle paths, equality checks, hot-root flush, reactions,
   per-kind lifetimes, and guarded app bootstrap. Test diamonds, changing
   dependencies, conditional cycles, escaped writers, reaction write-back,
   rejection of a second production context, and scene recreation without
   manual-state loss.
2. Add registrar-backed states and a small SwiftUI weather app. Verify per-ZIP
   updates, UI pinning, and equality-gated derived notices. Also test UIKit on
   an iOS 26 simulator.
3. Port `js-reactivity-benchmark`. Compare inline `AnyHashable`, interned key
   tokens, and generic keyed value references, including keyed diamonds.
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

| Feature                                                                                                    | Swift | OS runtime                 |
| ---------------------------------------------------------------------------------------------------------- | ----- | -------------------------- |
| `@Observable`, registrar, `withObservationTracking` (SE-0395)                                              | 5.9   | iOS 17 / macOS 14          |
| SwiftUI property tracking and `@Bindable`                                                                  | 5.9   | iOS 17                     |
| `Mutex`, `Atomic` (SE-0433, SE-0410)                                                                       | 6.0   | iOS 18 / macOS 15          |
| `sending`, `@isolated(any)`, region isolation (SE-0430, SE-0431, SE-0414)                                  | 6.0   | Compile-time               |
| Isolated deinit (SE-0371)                                                                                  | 6.1   | About iOS 18.4             |
| Default MainActor isolation, caller-isolated async, `@concurrent`, task names (SE-0466, SE-0461, SE-0469)  | 6.2   | Compile-time / 6.2 runtime |
| `Observations`, `Task.immediate` (SE-0475, SE-0472)                                                        | 6.2   | iOS 26; not back-deployed  |
| UIKit/AppKit automatic tracking and `updateProperties()`                                                   | —     | iOS 26; opt-in from iOS 18 |
| `weak let` (SE-0481)                                                                                       | 6.3   | Compile-time               |
| Continuous tracking, async `defer`, cancellation shields, `~Sendable` (SE-0506, SE-0493, SE-0504, SE-0518) | 6.4   | Newer “OS 27” family       |

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

**A locked graph** can run anywhere with one lock per context — per-state locks
would make dynamic edges a deadlock problem — but even one lock cannot make a
whole SwiftUI render atomic: the graph could commit between two view reads.
Fixing that needs version-pinned snapshots, and SwiftUI gives no render start
and end hooks. This design also makes every cross-thread value `Sendable`.

**A background graph with immutable snapshots** gives coherent reads, but a
control such as `TextField` needs its write visible on the next immediate
read. A main → background → main trip can drop characters or move the cursor,
and keeping form state on main would create two state systems.

Do not use a second context as an escape hatch. Expensive work may use another
executor, but authoritative state returns to the one app context through an
async result or op. This keeps the cheap case cheap: small selectors such as
`temperature > 68` stay on main, and graph bookkeeping never crosses an
executor.

## Appendix D: ecosystem survey details

- Early Solid and preact ports were small and stopped before Observation;
  unixzii/swift-signal had about 55 stars and ended in 2024.
- swiftui-atom-properties (~338 stars) is the strongest Recoil-style prior
  art: keyed and async atoms, scopes, effects, and automatic release. Its
  parameterized `Hashable` keys inform `CogBox`, though its model is
  view-centered and rooted in one store.
- swift-state-graph (~67 stars at survey time) is active and close in purpose:
  generic class states, explicit dependency capture lists, no named turn model.
- TCA's macros and feature structure set a useful upper limit on Cog's
  complexity. Reports of roughly 200 lines of setup and large macro build-time
  costs support an API that reads like values and methods.
- `AsyncSequence`, `share()`, and work on `flatMapLatest` are closing old
  stream gaps without Combine, which has seen little change since about 2020.
- Existing Swift query projects have not produced a standard; surveyed
  TanStack-style attempts total fewer than 500 stars. Useful ideas include
  predicate-based staleness, tag invalidation, and separate freshness and
  retention clocks. swift-sharing covers persistence keys but not that full
  query model.
- Common `@Observable` pain points match Cog's scope: uncached derived values,
  equal-set notices, weak cross-object propagation, whole-collection tracking,
  and view-owned lifetime mistakes.
- Reactively and alien-signals provide the push-pull graph model; alien-signals
  publishes port-ready pseudocode and now underlies Vue 3.6.
- `.latest` replaces the Dart draft's proposed `.allAtOnceInOrder` default.
  Latest-wins is safer for UI state because an old request cannot overwrite a
  new one.

[^observation-mechanics]:
    `@Observable` rewrites stored properties into computed accessors: getters
    call `access(keyPath:)`, setters call `withMutation(keyPath:)`. SwiftUI
    evaluates `body` in an observation scope and captures exactly the
    properties read; UIKit and AppKit use the same model on newer OS versions.
    shareup/Signals proves that a hand-written `value` property can join this
    boundary.

[^tracking-storage]:
    Observation uses thread-local storage for its active tracker. Since Cog
    never leaves the MainActor during sync graph work, one actor-isolated
    stack or slot is enough, pushed and popped around state computations and
    reactions.
