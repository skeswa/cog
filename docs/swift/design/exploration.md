# Cog for Swift: core design

_August 9, 2026_

_See [README.md](../README.md) for the document map._

Cog is a fine-grained state library for SwiftUI: a change updates only the
derived values and views that used it. Cog uses Apple's Observation system at
the UI edge and its own dependency graph inside. This document covers the core
design; [rx.md](./rx.md) holds §5.4 and [mechanisms.md](./mechanisms.md)
holds §6.

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
4. **Keep state singular:** one running app has one authoritative `Cogs`,
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

- Tracking sees only synchronous subscript reads in the tracked scope. Reads
  in later closures or on another thread do not count. The `c[...]` spelling
  makes the tracked operation visible.
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
- A **state** is one source or derived value in the app `Cogs`, or in the
  one isolated context of a test or preview runtime.
- A **turn** is one outermost `commit` and the work it causes.
- A **hot root** has a live UI, reaction, or stream consumer. A cold state does
  not.

A “correct read” is a value derived from all source writes in the latest
completed turn. It does not mean outside data is always fresh: an async cog
may be pending or showing a previous value, but `CogStatus` makes that
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

### 2.3 Descriptors name state; `Cogs` stores it

A top-level declaration is a light descriptor, not a live global value. The
app's one `Cogs` stores the state for each descriptor and optional key; a
test or preview runtime has its own isolated context. This split gives Cog
keyed boxes (a box plus a key finds one state), singular state (every feature
resolves through one graph), clean tests (no process-global reset), and one
history owner for every turn and recomputation.

Production code must not create child contexts. Truly view-local state stays
in SwiftUI `@State`. Cog-backed screen state lives in the app graph, keyed by
a screen identity when needed, and resets through an explicit op. One mutable
domain fact gets one manual source; another feature may read it or derive a
new shape, but must not mirror it into a second `ManualCog`.

Production construction is guarded: the plain `Cogs` initializer is
`package`, so application code cannot name it at all. The app's bootstrap
calls `Cogs.bootstrapApp(mechanisms:)` once, at launch; a second call fails
fast in debug and release builds. The mechanism list is the only registration
point for side effects (§6.3). The `CogTesting` product adds
`Cogs.forTesting(seeding:mechanisms:)`, which hands a test or preview runtime
a fresh isolated context as often as it asks — seeded, then operating the
same mechanism list the same way — and never registers as the production
context.

The two spellings differ in grammar on purpose. Creating the app's context is
a once-per-process act, so it reads as a verb; creating a test context is
ordinary value creation, so it reads as a noun phrase.

`bootstrapApp(mechanisms:)`'s return value is the production ownership
handle. The app keeps it, passes explicit context only at non-view
composition boundaries such as isolated test harnesses, and injects it above
every scene. Every view that
interacts with Cog resolves that same object directly through the `\.cogs`
environment value; no view accepts, stores, or forwards `Cogs`. Ops are
ordinary methods in extensions of `CogOps` (§3.2), so `Cogs` and a
mechanism's controller share every op. There is deliberately no ambient
`Cogs.app`: code outside SwiftUI receives the context at its composition
boundary, which keeps the same feature usable with an isolated testing context
and avoids a separate missing-bootstrap trap contract.

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

Reads go through the active capability: `c[valueReference]` inside a selector
or reaction, and `cogs[valueReference]` at the Observation boundary. The shared
subscript is the normal tracked-read spelling. `c.peek(...)` and
`cogs.peek(...)` make non-tracking reads visibly exceptional. A `Writer`, also
named `c` at the call site, uses its distinct static type to make that same
subscript expose and stage the active turn's values. A callable value reference
would put graph work on what is otherwise an inert name and still need the
context as an argument.

### 2.4 Dependencies are captured on every run

Dependencies are exactly the cogs read with `c[...]` during the last run.
Conditions and early returns are valid; every edge must be read again on the
next run to stay attached. The runtime places the current consumer in a
MainActor tracking slot while a selector or reaction runs, and each tracked
subscript read links producer to consumer.[^tracking-storage]

Rules:

- Reuse dependency edges across runs; remove any edge not read again. The
  selected physical layout is a shared linked edge pool: indices avoid
  per-edge ARC, stable ordered reads reconcile in place, and a free list
  recycles removed entries (perf §3.3, §9.6).
- Track CLEAN, CHECK, and DIRTY state plus version numbers to skip work when
  no parent value really changed.
- Compare old and new values after every computation: use `Equatable` when
  available, allow a custom `equals:`, and treat non-equatable values as
  changed.
- Mark a state while its selector runs. Reading any marked state is a cycle:
  fail in every build and show the full descriptor-and-key path. An internal
  seam lets tests inspect diagnostics without crashing the test process.
- Synchronous selectors do not throw in v1. Use `Result` for fallible sync
  domain work and `CogStatus` for async failures.
- `c.peek` returns a cog's current value without creating an edge — the
  untracked escape hatch for a value the selector uses but must not follow, as
  in `withLatestFrom` (§5.4). Non-tracking reads still settle: `c.peek` and the
  one-shot `cogs.peek` compute a dirty value before returning it, so skipping
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

Declaration names make state-reference shape visible wherever a read occurs.
A keyless manual, derived, async, or read-only value reference ends in `Cog`;
a box ends in plural `Cogs`. Any narrower role comes first, as in
`weatherServiceSourceCog` or `weatherReportSourceCogs`. The app runtime remains
the ordinary local `cogs`, and a value read from the graph takes an ordinary
domain name without either suffix.

Application code unwraps every graph read into that ordinary domain name
before using it. Removing the declaration suffix makes references and values
visually distinct, keeps dependent reads in lexical data-flow order, and
prevents graph access from hiding inside a larger expression:

```swift
let someWords = cogs[someWordsCog]
let anotherThing = cogs[anotherThingCogs[someWords]]
let hereIsAnother = cogs.status[hereIsAnotherCog]
```

The rule is the same in SwiftUI bodies, selectors, reactions, and operations,
and for one-shot peeks. A status local deliberately does not add `Status` to
the domain name: its static `CogStatus` type carries that distinction. Binding
the returned status observes no field by itself; reading `hereIsAnother.kind`
or `.value` afterward still registers only that field at the SwiftUI boundary.
Writer lvalues and commands such as `refresh` that accept a value reference
are not value unwrapping and remain direct.

```swift
// WeatherState.swift

fileprivate let weatherServiceSourceCog = ManualCog<WeatherService>(.live)
let weatherServiceCog = weatherServiceSourceCog.readOnly

fileprivate let weatherReportSourceCogs = ManualCogBox<Weather?, ZipCode>(nil)
fileprivate let heatAdvisorySourceCogs = ManualCogBox<Bool, ZipCode>(false)
fileprivate let currentZipSourceCog = ManualCog<ZipCode?>(nil)

let weatherReportCogs = weatherReportSourceCogs.readOnly
let heatAdvisoryCogs = heatAdvisorySourceCogs.readOnly
let currentZipCog = currentZipSourceCog.readOnly

let isSunnyCogs = CogBox<Bool, ZipCode> { c, zip in
    let weatherReport = c[weatherReportCogs[zip]]
    return switch weatherReport?.kind {
    case .clear, .partlyCloudy: true
    default: false
    }
}

let isNiceOutsideCogs = CogBox<Bool, ZipCode> { c, zip in
    guard let weatherReport = c[weatherReportCogs[zip]] else { return false }
    let isSunny = c[isSunnyCogs[zip]]
    guard isSunny else { return false }
    let heatAdvisory = c[heatAdvisoryCogs[zip]]
    return weatherReport.temperatureF > 60
        && weatherReport.temperatureF < 90
        && !heatAdvisory
}

let isNiceOutsideHereCog = Cog { c in
    guard let currentZip = c[currentZipCog] else { return false }
    let isNiceOutside = c[isNiceOutsideCogs[currentZip]]
    return isNiceOutside
}
```

The public forms are:

| Declare           | Example                                  | Read                                             |
| ----------------- | ---------------------------------------- | ------------------------------------------------ |
| One derived value | `Cog<Bool> { ... }`                      | `c[valueReference]` → `Bool`                     |
| A derived box     | `CogBox<Bool, ZipCode> { ... }`          | `c[box[zip]]`                                    |
| One source        | `ManualCog<ZipCode?>(nil)`               | Read normally; write `c[valueReference] = zip`   |
| A source box      | `ManualCogBox<Weather?, ZipCode>(nil)`   | `c[box[zip]] = report`                           |
| One async value   | `AsyncCog<Forecast?> { ... }`            | `c[valueReference]` → `Forecast?`                |
| An async box      | `AsyncCogBox<Weather?, ZipCode> { ... }` | `c[box[zip]]`; status via `c.status[...]` (§5.1) |

Four rules keep these forms consistent:

1. **Value references are the only inputs to runtime APIs.** `Cog<T>` is readable;
   `ManualCog<T>` is readable and writable. A value reference is a value pairing an
   internal final-class descriptor with an optional key; identity is
   descriptor plus key (§2.3).
2. **Boxes create value references.** `box[key]` returns a value reference. A keyless declaration is
   the same system already bound to its only state.
3. **Production kind does not change the read type.** Manual, derived, and
   async describe how a value is made. `c[...]` of an async value reference is
   an ordinary total read of `T`, resting on the declaration's default until
   work first succeeds; the request lifecycle is read through the `status` lens
   (§5.1).
4. **Frequent call sites stay short.** `c[...]`, `commit`, and `box[key]` are
   common. The exceptional non-tracking operation is the explicit `peek`.
   Longer names such as `ManualCogBox` appear only at declarations.

The semantic and v1 physical shapes are settled. Keyed references use inline
`AnyHashable?`; the public type remains resilient rather than `@frozen`.
Keyed-diamond and churn measurements did not justify the interned candidate's
global lock/table or the generic candidate's permanent keyed overload surface
(perf §4 and §9.6). Both remain available only behind the test-and-benchmark
layout selector so behavior parity and the recorded comparison stay
reproducible.

Keys pass through normal lexical capture, as `zip` does above — there is no
hidden key flow. States appear lazily per descriptor and key. A manual box's
initial value may also be a key-based closure.

### 3.2 Ops and turns

```swift
extension CogOps {
    func checkWeather(_ zip: ZipCode) async throws {
        let service = peek(weatherServiceCog)

        async let report = service.weather(for: zip)
        async let advisories = service.advisories(for: zip)
        let (r, a) = try await (report, advisories)

        commit { c in
            c[weatherReportSourceCogs[zip]] = r
            c[heatAdvisorySourceCogs[zip]] = a.contains { $0 is HeatAdvisory }
        }
    }

    func selectCurrentLocation(_ zip: ZipCode) {
        commit(currentZipSourceCog, to: zip)
    }
}
```

`commit` is the only write entry point. Its scalar overload handles the common
one-source operation; the writer overload groups related writes into one turn.

- Only `Writer` can change a source. It supports read and write, so
  `c[countCog] += 1` works.
- Each writer carries an unforgeable turn ID and checks that its context is
  still accumulating that turn. An escaped writer cannot be used later.
- `#function` names the turn without extra code. An op is just a normal
  method that calls `commit`, written in an extension of `CogOps` — the
  small protocol carrying `commit`, `peek`, and `refresh` that both `Cogs`
  and a mechanism's controller adopt. One definition serves views, app code,
  and mechanisms; pass a custom name only when needed.
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
m.run { c in
    let isNiceOutsideHere = c[isNiceOutsideHereCog]
    if isNiceOutsideHere {
        notifier.alert("It is nice outside!")
    }
}
```

A reaction runs once when registered to record dependencies, and again after a
turn changes one of them, always against settled state. Reactions register
only through a mechanism's controller — `m.run` for several dependencies,
`m.watch` for one cog's old and new values — so every reaction has a named,
bootstrap-registered owner (§6.2–§6.3). Outside a flush, the initial run
happens before `m.run` returns. During a flush, registration does not
re-enter the reaction that made it: the initial run joins the tail of that
flush's reaction queue in registration order, after reactions already
scheduled for the turn and before queued write-back turns begin. There is no
public reaction handle: a reaction lives until its owning scope ends — the
app runtime for a mechanism's top-level registrations, or the gated
`whenever` scope that made it (§6.2). §6 covers mechanism ownership, timers,
registration, and reaction write-back.

### 3.4 SwiftUI

```swift
struct WeatherCard: View {
    @Environment(\.cogs) private var cogs
    let zip: ZipCode

    var body: some View {
        let weatherReport = cogs[weatherReportCogs[zip]]
        let isNiceOutside = cogs[isNiceOutsideCogs[zip]]

        VStack {
            Text(weatherReport.map { "\(Int($0.temperatureF.rounded()))°F" }
                 ?? "No weather report yet")
            Text(isNiceOutside ? "Go outside!" : "Stay in.")
            Button("Check the weather") {
                Task { try await cogs.checkWeather(zip) }
            }
        }
    }
}
```

`cogs[valueReference]` reads through the state's registrar, so SwiftUI tracks
that exact descriptor and key and updates the view only when one of those
values really changes. There is no special view, hook, or property wrapper;
the app injects its one `Cogs` above every scene through the environment.
Every view that reads or acts on Cog declares
`@Environment(\.cogs) private var cogs` itself. A parent never passes the
runtime through a view initializer, and an intermediate view that does not use
Cog does not resolve it merely to forward it; views pass domain values and
identities instead. Tests and previews install their isolated context above the
hosted hierarchy with the same `.cogEnvironment(cogs)` modifier.
SwiftUI does not tell Cog when it stops watching a registrar object, so any
state that reaches this UI boundary stays pinned to the app context (§5.3).

Sources are `fileprivate`, so views cannot name writable references. The state
file may export an ordinary SwiftUI adapter when a control requires `Binding`:

```swift
// WeatherState.swift
extension Cogs {
    func selectCurrentLocation(_ zip: ZipCode?) {
        commit(currentZipSourceCog, to: zip)
    }

    var currentZipBinding: Binding<ZipCode?> {
        Binding(
            get: { self[currentZipCog] },
            set: { self.selectCurrentLocation($0) }
        )
    }
}

// A view
TextField("ZIP", value: cogs.currentZipBinding, format: .zipCode)
```

`Binding` needs no Cog-specific primitive: its getter already uses the tracked
subscript, and its setter calls the existing domain operation. Cog therefore
does not vend binding helpers. The single-source `commit(_:to:)` overload keeps
that operation compact while preserving `commit` as the only write boundary.
Multi-source and read-modify-write operations keep the writer form. For a
one-time untracked read, use `cogs.peek(...)`.

---

## 4. Write ownership

Swift access control replaces the custom lints proposed for Dart:

- Declare writable sources `private` or `fileprivate`; both are fine, and at
  file scope the two spellings are identical (the formatter prefers
  `private` there). Only that file or type can name them.
- Expose `.readOnly` value references or derived cogs.
- Put ops, UI adapters, and test seams beside the sources they may write.

Callers can use `try await cogs.checkWeather(zip)` but cannot reach
`weatherReportSourceCogs`. A review finds every possible write by searching one
file's commit blocks.

`@testable import` cannot see `fileprivate` sources, so the owning file may
publish narrow debug-only source capabilities. Test support imports
`CogTesting` to seed those capabilities or calls loud commit helpers from the
owning file; §6.6 shows both paths. Making all sources `internal` would weaken
the rule from one file to one module.

---

## 5. Async cogs

### 5.1 Values and work

Async state uses one status type and keeps a renderable value in every kind:

```swift
struct CogStatus<Value> {
    enum Kind {
        case pending
        case success
        case failure
    }

    var kind: Kind { ... }
    var value: Value { ... }
    var hasSucceeded: Bool { ... }
    var error: (any Error)? { ... }
    var isLoading: Bool { ... }
}
```

Status is how uncertainty stays explicit, but it is not how an async cog
is normally read. Reading an async cog is total: `c[...]` returns `Value` —
the last accepted success, or the declaration's resting default before any
generation has succeeded — so sync and async cogs read identically wherever
only the value matters. The request lifecycle moves behind the `status` lens
on the same read capability, and consumers opt into it exactly where they
render the request itself.

There is no public `initial` kind. Before first use, an async state does not
exist in the context and has no status to observe. The first read through
either spelling creates the state, starts its work, and publishes
`kind == .pending`, `value == default`, and `hasSucceeded == false` as a turn;
a status read returns those fields atomically, while a value read returns the
same resting default the declaration vouched for. This keeps the first
observable state honest: work has begun, no value has completed yet, and the
only value shown is one the author chose for exactly that moment.

Every read spelling follows that rule. A non-tracking `c.peek` or one-shot
`cogs.peek` of a never-read async value reference creates its state, runs its
synchronous selector, starts exactly one generation, publishes the initial
pending turn, and returns its spelling's view of it — the resting default
from a value peek, the pending status from a `status` peek. It records no
dependency, subscription, or Observation boundary. Refreshing a never-read
value reference is the same single initial load: it is not a no-op, and it
does not create the state only to replace and cancel that first run. Once a
state exists, refresh follows the replacement policy in §5.2.

`value` answers “what should be on screen” in every lifecycle state: the
current or retained success, resting on the declared default until one exists.
`hasSucceeded` keeps optional values honest: when `Value == Optional<T>`, a
`nil` value plus `false` means the resting default, while the same `nil` plus
`true` means an accepted successful `nil`. This is stronger and flatter than
a nested `Previous<Value>` wrapper and eliminates the weaker optional-valued
status accessors. `error` is non-`nil` only for the current failure, while
`isLoading` and `hasSucceeded` remain orthogonal. `kind` holds only pending,
success, or failure; switching on `status.kind` renders the whole process while
associated data stays in independently readable fields. There is no failure
type parameter in v1; typed throws may add one once the required Swift and OS
versions are practical.

Total reads rest on an explicit declared default. Every async declaration
spells `default:`, including optional values, which use `default: nil`. The
argument makes the rendering invariant visible where the request is declared
without adding a protocol or hidden type-wide behavior. Choose defaults whose
rendering is honest while work is in flight — a zero unread count reads
truthfully during a first load; an empty message list claims an answer nobody
has yet, and belongs behind an optional instead.

An async selector is synchronous and tracked. It reads dependencies, then
returns a description of async work:

```swift
let fetchedWeatherCogs = AsyncCogBox<Weather?, ZipCode>(
    .latest,
    default: nil
) { c, zip in
    let weatherService = c[weatherServiceCog]
    return .run { try await weatherService.weather(for: zip) }
}
```

§3.1 modeled `weatherReportCogs` as a manual box that the `checkWeather` op fills;
`fetchedWeatherCogs` is the async alternative, where the fetch itself is derived
state. A real app picks one shape per fact — the two appear side by side here
only to compare them.

`Work` has two forms: `.run { ... }` returns one value, committed as one turn;
`.stream(sequence)` commits each changed sequence element as its own turn. The
split prevents hidden async tracking bugs: every `c[...]` read happens before
the work starts, so no read can silently stop tracking after an `await`.
Changing a dependency reruns the selector and creates new work; the policy in
§5.2 decides what happens to the old work.

Read the value normally:

```swift
let fetchedWeather = c[fetchedWeatherCogs[zip]] // Weather? — total value
```

Or opt into the lifecycle through the `status` lens while keeping the same
unsuffixed domain name:

```swift
let fetchedWeather = c.status[fetchedWeatherCogs[zip]] // CogStatus<Weather?>
```

Every read capability carries the same pair: `c[...]`, `c.peek(...)`, and
`m.watch(...)` read and observe the value, while `c.status[...]`,
`c.status.peek(...)`, and `m.status.watch(...)` read and observe the status,
with identical demand and lifetime rules. At the SwiftUI boundary,
`cogs.status[...]` defers Observation registration to the returned status's
field getters: `kind`, `value`, `hasSucceeded`, `error`, and `isLoading` each
invalidate only when that field changes. Selector and reaction status reads,
and explicit status watches, continue to track the complete atomic status. The
lens exists only for async references — asking a synchronous cog for status is
a compile-time error, not a degenerate success. Value consumers are
equality-gated when `Value` is `Equatable`: a reload that succeeds with an equal
value still shows complete-status consumers its pending and success turns, but
leaves value consumers quiet. The same equality rule applies to a SwiftUI
`status.value` field read. The value read therefore lets downstream code treat
a manual `Weather?` and an async weather value as the same shape. Use
`AsyncCog` for async derived state and an op for an imperative action. A forced
refresh returns a `CogRefresh` handle whose `outcome` belongs to that exact
generation: success and failure resolve after their publication turn,
replacement resolves as `superseded`, and state release resolves as `released`.
The handle never waits for or reports a later generation.

One status read is the normal shape for request chrome: `status.value` shows
the retained or resting content while `status.kind` and the neighboring fields
describe the request. SwiftUI records only the getters the body actually uses;
switching on `status.kind` does not implicitly subscribe that body to `value`,
`error`, or either flag. Code that needs only the equality-gated value keeps the
plain `c[...]` spelling and stays quiet for pending, failure with an unchanged
value, and equal success.

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
work does not publish a failure; the replaced `CogRefresh` handle resolves as
`superseded`.

A failed `.queue` run publishes its failure normally, resolves any refresh
handle for that exact run as failure, and then starts the next accepted request.
Failure is a result of one request, not cancellation of the ordered scheduler;
stopping would silently strand work Cog already accepted and leave the derived
value behind its newest dependencies. The next run publishes its own pending
turn with the last successful value (or the declared default) before it runs.

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

Natural stream termination is not a fourth lifecycle state or a synthetic
value. Ending publishes no turn, does not restart the selector, and leaves the
most recent status intact. A stream that emitted an element therefore rests at
its last success. An empty stream remains pending on the declared default with
`hasSucceeded == false`: manufacturing success would claim an element that did
not exist, while manufacturing failure would turn normal `AsyncSequence`
completion into an error. A dependency change or explicit refresh starts a new
generation under the ordinary `.latest` rules. Sources for which an empty end
is exceptional should express that as a thrown error, whose status is settled
below.

An error thrown by the still-current stream is an ordinary failure turn. It
retains the last successful element (or the declared default before one),
records the error, and does not restart automatically. A refresh handle
resolves as failure if the sequence throws before its first accepted element;
once an element has resolved that handle as success, a later stream error does
not rewrite the already terminal outcome. Cancellation remains cause-sensitive:
replacement or release initiated by Cog publishes nothing, even when iteration
surfaces `CancellationError`, while a still-current sequence that Cog never
cancelled publishes any thrown error—including `CancellationError`—as failure.

Stream elements use the same equality rule as every other Cog state. For an
`Equatable` value, an element equal to the current success is discarded before
a graph turn exists: value and status consumers stay quiet, history gains no
entry, and a later different element still commits normally. Values without an
equality rule conservatively treat every element as changed. Cog is current
state, not an event-history transport; callers that must preserve duplicate
events keep that `AsyncSequence` in an op or reaction instead (§5.4).

### 5.3 Freshness and lifetime

A future query layer should support stale rules based on age, network return,
or app focus; tag-based invalidation across keyed boxes; a stream that yields
a disk value, then a network value; and separate clocks for freshness and
memory retention.

State lifetime depends on state kind:

- **Manual:** `.app` by default, because releasing a source would reset it on
  the next read. Ephemeral state may opt into
  `.whileObserved(resetToInitial: true)`, spelled as a `lifetime:` argument on
  the declaration and accepting the same optional `grace:` as any other
  `whileObserved` policy. `resetToInitial: false` asks for a source that is
  released without losing its value, which no released source can be, so it
  traps at the declaration in every build rather than losing a value at the
  first expiry. A source's transient demand is a one-shot `peek` or a write:
  either renews grace, and neither keeps the value alive on its own. A reaction
  that reads the source leases it and a UI read pins it, exactly as for derived
  state.
- **Sync derived:** `.whileObserved(grace:)` by default. Cog can recompute it.
- **Async:** `.whileObserved(grace:)` by default. Release cancels work,
  advances its generation, and blocks late results from a new slot.
- **Query:** explicit `.cache(...)` policy with separate freshness and
  retention rules.
- **UI boundary:** pinned to the app context in v1 because SwiftUI exposes no
  reliable observer-removal hook. Reactions and exported streams have exact
  lease tokens and may release normally.

Lifetime follows state kind rather than a declaration convenience flag. If
UI-pinned keyed growth becomes a measured problem, an optional
`DynamicProperty` can own an exact view lease.

A declaration that selects `whileObserved` without an explicit grace uses its
context's default. Production contexts use 30 seconds: long enough to absorb
ordinary UI reconstruction without making abandoned derived caches
effectively app-lifetime. `CogTesting` accepts a context override so lifetime
tests can inject both a controllable clock and an explicit duration; no test
waits for the production interval or wall-clock time.

A non-tracking read of synchronous derived or async state—and an async
refresh—is transient demand, not a durable lease. It invalidates an older
pending expiry while it runs, then starts a full grace window when the call
returns. Another one-shot demand renews that window; a UI, reaction, or stream
consumer that arrives during it keeps the same state and, for async state, the
same run. If no durable consumer arrives, ordinary `whileObserved` expiry
releases the state. Async release also cancels work and advances its generation,
so a late result cannot commit. The work does not retain itself until
completion: code that must finish with no consumer beyond the grace window
belongs in an imperative op or an app-lifetime declaration.

### 5.4 Where the Rx operators went

See [rx.md](./rx.md). It maps Rx behavior to dynamic dependencies, async
policies, and `.stream`, while keeping ordered event history outside the state
graph.

---

## 6. Side effects, worked

See [mechanisms.md](./mechanisms.md) for mechanisms, reactions, gated scopes,
bootstrap registration, view lifetime, testing, background work, and
reconciler rules.

---

## 7. What the SwiftUI boundary must handle

- **Reads in escaping closures are not tracked.** A `Button` action or
  `Task {}` body is outside the view's tracked read, so it uses the visibly
  one-shot `cogs.peek` spelling. Public Observation exposes no query for
  whether `ObservationRegistrar.access` found a current consumer: a valid
  SwiftUI, UIKit, or AppKit automatic-tracking read and an accidental
  `cogs[...]` in an action are indistinguishable to Cog. The direct subscript
  therefore emits no missing-consumer warning. Do not use private
  Observation SPI or a heuristic that would warn on valid reads; revisit the
  diagnostic only if Observation adds a public tracking-presence API.
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

| Question                          | Decision                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Who may write?                    | `private` or `fileprivate` plus `.readOnly` controls source names; a writer turn ID controls when writes are valid (§3.2, §4).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| Op, transaction, or turn?         | One named `commit`; ops are ordinary methods in `CogOps` extensions, so `Cogs` and a mechanism's controller share every op (§3.2).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| Keyed and keyless API?            | Boxes make value references; keyless cogs are pre-bound value references. The selected v1 layout carries keyed identity inline as `AnyHashable?`: it already creates references with zero allocations, while the measured interned candidate bought no consistent wall-time win for its global lock/table and the generic candidate regressed the keyed diamond while adding a permanent public overload surface. The public types remain resilient, and both losing candidates remain test-and-benchmark-only (§3.1; perf §4, §9.6).                                                                                                                                                                                                                                                                                                                                                      |
| Identity and names?               | Descriptor `ObjectIdentifier` for process identity; explicit name or `fileID:line` for people. Public `Cog` and `ManualCog` types are value references over internal final-class descriptors. Declaration variables end in singular `Cog` for one keyless value reference and plural `Cogs` for a box; narrower qualifiers precede the suffix (§2.3, §3.1).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| Static or dynamic dependencies?   | Dynamic, captured on each run (§2.4).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| Physical edge layout?             | A shared linked pool of compact indexed entries. It used 3.1–3.4% fewer instructions than prefix arrays and inline-plus-overflow on the expected mostly-static shape, while all three tied on wall time and allocations. Prefix arrays won the deliberately high-churn instruction count but not wall time and added per-turn ARC; inline-plus-overflow won neither workload. Both losing layouts remain test-and-benchmark-only (perf §3.3, §9.6).                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| Shipping core after M6?           | The simple class-state core remains the shipping default; there is no 0.2.0 release. Arena passes the same 248 public behavior scenarios and improves p50 wall clock on diamond, broad, unstable, and wide propagation, but regresses deep instructions and the smallest steady turn, still allocates five times per turn, retains/releases hundreds of times during propagation, and pays exactly two retain/release pairs per pinned key where simple pays one. It therefore misses M6's zero-cost goals and preserves the explicit O(pinned keys) defect with a steeper ARC slope. Arena plus its selected shared edge pool remains an internal selector-only research and benchmark candidate. Reconsider replacement only after pinned-key work becomes O(changed) and representative shapes show no new common-path regression (perf §9.6).                                          |
| Cycles and selector errors?       | Show the keyed computing path and fail. Sync selectors do not throw in v1 (§2.4).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| Writes from derived computation?  | A derived computation is read-only from selector entry through dependency reconciliation, custom equality, and result publication. Any commit attempted in that region fails immediately in every build, before the commit body runs or that attempt mutates graph state, and names the derived cog/key plus the attempted turn. Invoke the op outside derived computation, from event handling or a reaction (§2.4, §3.2).                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| Consistent updates?               | Lazy pull for reads; settle hot roots before push notices (§2.2, §3.2).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| Key flow?                         | Normal lexical capture in a `CogBox` closure (§3.1).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| Async value shape?                | Async reads are total and value-first: `c[valueReference]` returns `Value` — the last accepted success, resting on the declaration's explicit `default:` before one exists — and the request lifecycle is read through the `status` lens (`c.status[...]`), which exists only for async references. Optional values spell `default: nil`; there is no default protocol or argument omission. `CogStatus.kind` begins publicly at `pending`—there is no observable `initial` kind. Pending and failure retain a total `value` plus `hasSucceeded`, which distinguishes a resting optional `nil` from an accepted successful `nil` without a nested wrapper. `kind`, `value`, `hasSucceeded`, `error`, and `isLoading` are independently observed at the SwiftUI boundary (§5.1).                                                                                                            |
| Never-read async demand?          | A non-tracking peek or refresh creates the state and starts exactly one initial generation with `kind == .pending`, `value == default`, and `hasSucceeded == false` without installing a dependency, subscription, or Observation boundary. The call is transient demand: it renews the ordinary `whileObserved` grace window but does not retain work through completion, and expiry cancels, advances the generation, releases, rejects late results, and resolves an exact refresh handle as `released` (§5.1, §5.3).                                                                                                                                                                                                                                                                                                                                                                   |
| Async dependency tracking?        | A sync selector returns `Work`; no reads cross `await` (§5.1).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| Default async policy?             | `.latest`. `refresh` returns an exact-generation `CogRefresh`: accepted publication resolves as success or failure, replacement as `superseded`, and lifetime removal as `released` (§5.1–§5.3).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| Queued run failure?               | A failed `.queue` run publishes failure and resolves its exact refresh handle, then the next accepted request starts in order. A failure belongs to one request; it does not cancel the scheduler or strand later accepted work (§5.2).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| Exhaust for derived state?        | `.exhaustLatest` catches up once; true drop belongs to ops (§5.2).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| Rx operators and temporary edges? | Dynamic links, async policies, and `.stream`; every edge is recaptured (§5.4).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| Mechanism lifecycle?              | A `Mechanism` is the bundled unit of side effects: a protocol with a defaulted `name` and one `operate(_:)` requirement, adopted by structs and classes alike. `Cogs.bootstrapApp(mechanisms:)` is the only registration point; each `operate` runs synchronously in array order inside bootstrap, operate-time writes settle before bootstrap returns, duplicate names fail fast, and no late installation exists. The runtime retains the supplied mechanism values with their scopes; teardown cancels scopes before releasing those values. Registration handles stay internal: a mechanism's top-level registrations live for the app runtime, every shorter lifetime is a state-gated `whenever` scope whose fall cancels its registrations and whose next rise re-runs the body fresh, and scope cancellation remains terminal and idempotent as an internal invariant (§6.2–§6.3). |
| Mechanism controller?             | `operate` receives a curated final-class `MainActor` controller and never raw `Cogs`: registration (`run`, `watch`, `task`, `whenever`), untracked `peek`, and the shared `CogOps` ops surface (`commit`, `refresh`). A scope retains its controller without the controller owning the runtime; work that may outlive the scope installs a weak controller callback, which becomes inert when the scope ends. Registration names compose under the mechanism's `name` for debug history and Instruments, and turns opened through the controller record their mechanism. View-lifetime work stays with SwiftUI `.task` and `values` (§6.2, §6.5).                                                                                                                                                                                                                                          |
| Writes from reactions?            | Queue a new turn after the current flush; never re-enter. A debug turn-chain guard reports long causal chains through a testable diagnostic seam (§6.4).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| Reaction registration in a flush? | Do not run the new reaction reentrantly. Append its initial tracking run to the tail of the current flush's reaction queue, in registration order: after reactions already scheduled for that turn and before queued write-back turns begin (§3.3).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| Test seeding?                     | Debug-only `CogTesting.seed` stages a value and pushes dirty flags like a write, but records no turn, sends no notices, and runs no reactions. `Cogs.forTesting(seeding:mechanisms:)` runs its seeding closure after the context exists and before any `operate`, so arranged state precedes mechanism startup; there is no late-start API even for tests. Apps importing only `Cog` cannot seed (§6.6).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| Accumulating versus flushing?     | Nested commits join while accumulating and queue while flushing (§3.2).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| Streams with async policies?      | `.stream` is `.latest`-only and the type system enforces it (§5.2).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| Natural stream termination?       | Natural end publishes no turn and starts no replacement. The most recent status remains: last success after an element, or pending on the declared default with no accepted success after an empty sequence. Dependency change or refresh starts a new generation; a source that treats empty end as exceptional throws (§5.2).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| Throwing stream failure?          | An error from the still-current stream publishes failure, retains the last success or declared default, and starts no replacement. Before a first element it resolves an exact refresh handle as failure; after an element the handle has already resolved as success and does not change. Cog-initiated replacement or release cancellation stays silent, while a `CancellationError` Cog did not initiate is an ordinary failure (§5.2).                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| Equal stream elements?            | Stream elements follow ordinary state equality. An `Equatable` element equal to the current success creates no turn, notice, or history entry; a later changed element commits normally. Without an equality rule every element conservatively counts as changed. Duplicate event history belongs in an op or reaction, not a cog (§2.4, §5.2, §5.4).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| State disposal?                   | Per-kind `app`, `whileObserved`, or `cache`; never infer UI liveness from graph edges. A `whileObserved` declaration without an explicit grace uses its context's 30-second production default, and `CogTesting` can override that context default alongside its injected clock. Sources take that policy through a `lifetime:` argument and must say `resetToInitial: true`, because releasing a source can only start it over; the impossible `false` spelling traps at the declaration (§5.3).                                                                                                                                                                                                                                                                                                                                                                                          |
| State graph count?                | One app-wide `Cogs`. Tests and previews are separate runtimes with one isolated context (§2.3).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| Untracked reads?                  | `c.peek` and one-shot `cogs.peek` skip the dependency edge but still settle the value they return; an untracked read is never stale. Peeking a `whileObserved` synchronous derived or async state is transient demand that renews ordinary grace without installing a durable consumer (§2.4, §5.3).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| Read spelling?                    | Use `c[valueReference]` for tracked selector and reaction reads, `cogs[valueReference]` for tracked UI reads, and `c.peek(...)` or `cogs.peek(...)` for non-tracking reads. Async status reads through the `status` lens on the same capability — `c.status[...]`, `cogs.status[...]`, `c.status.peek(...)`, `m.status.watch(...)` — with the same tracking, demand, and lifetime rules as the value spelling beside it. Commit closures also call their `Writer` parameter `c`; its distinct type makes the same subscript expose and stage the active turn's values (§2.3, §3.2, §3.4, §5.1).                                                                                                                                                                                                                                                                                            |
| Export buffer overflow?           | `.newest(1)` may skip turns for a slow reader; `.oldest(n)` delivers the oldest n in order and drops newer while full; `.unbounded` delivers everything. Commits never wait on readers (§8).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| External Observation tracking?    | After an observed mutation propagates, dependents see its newest post-mutation value; mutations may coalesce. The pre-iOS-26 one-shot shim internally acknowledges re-arming but retains a documented disarmed race (§8).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| Context construction?             | App bootstrap calls `Cogs.bootstrapApp(mechanisms:)` once; feature code cannot construct another context (§2.3).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| Bootstrap helper names?           | `Cogs.bootstrapApp(mechanisms:)`, vended by `Cog`, creates the one production context, operates its mechanisms in order, and fails fast on a second call; `Cogs.forTesting(seeding:mechanisms:)`, vended by `CogTesting`, returns a fresh isolated context as often as a test or preview asks. A `package` initializer leaves those two as the only ways in, and separating them by product rather than by an argument keeps the test factory out of a shipping app target (§2.3, §6.3, §6.6).                                                                                                                                                                                                                                                                                                                                                                                             |
| Production context access?        | `bootstrapApp(mechanisms:)` returns the ownership handle; the app retains it, passes explicit context only at non-view composition boundaries such as isolated test harnesses, and injects it above every scene. Every consuming view resolves it directly through `\.cogs`; no view accepts or forwards it. Ops extend `CogOps`, so views call them on `cogs` and mechanisms call them on their controller. There is no ambient `Cogs.app`, so production and isolated tests use the same explicit composition boundaries (§2.3, §3.2, §3.4, §6.3).                                                                                                                                                                                                                                                                                                                                       |
| Production-install test fixture?  | `CogTesting` vends a synchronous MainActor `withBootstrappedApp` scope plus narrow install predicates. It calls the real bootstrap and removes the registration in `defer`; it is deliberately not async, so parallel tests cannot interleave through process-global install state (§2.3; impl scenarios constraint 3).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| Testing posture?                  | Fully optimistic (every wait is a definite injected signal: `CogTesting.TestClock`, continuations, exact refresh handles, or narrow acknowledgements), as fast and cheap as possible (host-first; simulators only at the device boundary; injected time everywhere, including `whileObserved` grace), and as implementation agnostic as possible (public API, then `CogTesting`, then debug history, then named diagnostic seams; the behavior suite passes unchanged across core swaps). Normative statement in impl/scenarios.md.                                                                                                                                                                                                                                                                                                                                                        |
| Trap spelling?                    | Fail-fast traps use `fatalError`, never `preconditionFailure`. The standard library drops `preconditionFailure`'s message under `-O`, so the process traps with no explanation and a promise of "a clear error … in release builds" (ONE-02, TURN-07, CYCLE-01, CYCLE-02) could not be kept. Measured on Apple Swift 6.3: under `-Onone` both spellings print; under `-O` only `fatalError` does, including under `-Ounchecked`. An exit test proving a trap asserts on the child process's standard error, not merely its exit status.                                                                                                                                                                                                                                                                                                                                                    |
| Generic class `deinit`?           | Every generic class in the library writes an explicit `nonisolated deinit`. Under `.defaultIsolation(MainActor.self)` a _synthesized_ `deinit` on a generic class is main-actor-isolated, and Apple Swift 6.3.0 and 6.3.3 both crash the optimizer on it (SIGSEGV in `EarlyPerfInliner`) in release configuration only. Debug builds are unaffected, so only a release build catches a regression — `mise run test:release` is the guard, and it runs in CI. The rule is independently correct, since these deinits only release their own stored properties and the classes are never `Sendable`. Revisit when the toolchain fixes it.                                                                                                                                                                                                                                                    |
| Implementation execution?         | Dependency-aware half-day tasks, each typed as a decision, infrastructure slice, red-green behavior slice, gate, or single publication step. Every task names its dependencies and closing verification and ends green; representation changes integrate incrementally, and releases separate non-mutating preparation from publication. Normative statement in impl/tasks.md.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| Public names for 0.1.0?           | Frozen as they stand. The chartered prior-art review of swift-state-graph (`M4-01a`, [prior-art.md](./prior-art.md)) reconsidered thirteen public names and renamed none. Both libraries capture dependencies dynamically from real reads; Cog keeps "who is reading" a value — the `Reader` spelled `c` — rather than ambient thread-local state, so a tracked read, an untracked `peek`, and a read outside any computation are all distinguishable in the source. `Cogs` naming both the runtime and every box's suffix is recorded as the one uncomfortable name, kept behind the existing disambiguation convention with a revisit trigger for 1.0.                                                                                                                                                                                                                                   |

### Still open

These numbers are stable identifiers that other documents cite. A settled item
keeps its slot and points at the table above instead of renumbering the rest.

1. **Read spelling:** settled on August 12, 2026 as `c[valueReference]` inside
   selectors and reactions, `cogs[valueReference]` at the UI boundary, and
   `peek(...)` for non-tracking reads. See "Read spelling?" above.
2. **How much `Op` support ships in v1:** plain `CogOps` extension
   methods are enough to start. `.live` and `.latestFailure` call tracking
   need a separate design.
3. **Deferred reactions:** synchronous ordered flush and the write-back queue
   are settled. An optional next-tick `.deferred` mode may or may not earn its
   complexity.
4. **App bootstrap:** settled on August 11, 2026, then amended on August 14,
   2026 by the mechanism redesign. Production calls
   `Cogs.bootstrapApp(mechanisms:)`; tests and previews call
   `Cogs.forTesting(seeding:mechanisms:)`, whose parameters default to no
   seeding and no mechanisms. Ownership/injection and the scoped `CogTesting`
   production-install fixture remain unchanged. See "Bootstrap helper names?",
   "Production context access?", and "Production-install test fixture?" above.
5. **Debug history UI:** the structured bounded snapshot records ops, writes,
   recomputations, and notices. Cog does not vend a logging convenience;
   display may be an in-app inspector or another developer tool.
6. **Dart and Flutter:** decide later whether a proven Swift model should feed
   descriptor, lazy-pull, and lexical-key choices back into Dart.
7. **Persistence helpers:** durable state writes the store first and its cog
   second (§6.7). Open whether this needs `PersistedCog` sugar or stays an op
   pattern, and when GRDB observation should replace seeding.
8. **Stream termination:** settled on August 17, 2026. Natural end publishes
   no turn, starts no replacement, and leaves the most recent status intact:
   last success after an element, or pending on the declared default after an
   empty sequence. Dependency change or refresh starts a new generation. See
   "Scheduling policies" above.
9. **Stream failure:** settled on August 17, 2026. An error from the
   still-current sequence publishes failure and starts no replacement;
   Cog-initiated cancellation stays silent. Exact refresh handles resolve at
   the first accepted element or an earlier failure and never change afterward.
   See "Scheduling policies" above.
10. **`.queue` failure:** settled on August 17, 2026. A failed queued run
    publishes failure and resolves its exact refresh handle, then the next
    accepted request starts in order. Failure ends one run, not the queue; Cog
    never strands work it already accepted. See "Scheduling policies" above.
11. **Writes from a selector:** settled on August 12, 2026. A commit attempted
    anywhere in a derived computation fails immediately in every build before
    the commit body runs or that attempt mutates graph state. See "Writes from
    derived computation?" above.
12. **`EffectGroup.add` after cancel:** settled on August 12, 2026, then
    superseded on August 14, 2026 by the mechanism redesign: no public group
    or token remains. The terminal, idempotent cancellation semantics survive
    as internal invariants of mechanism scopes. See "Mechanism lifecycle?"
    above.
13. **Timing modifiers:** §5.4 points `debounce` and `throttle` at "a
    reaction modifier or async-cog option," but no design or milestone
    exists. Deferred backlog.
14. **Equal stream elements:** settled on August 17, 2026. Ordinary state
    equality wins: an equal `Equatable` element creates no turn or notice,
    while a value without an equality rule treats every element as changed.
    Duplicate event history stays outside Cog state. See "Scheduling policies"
    above.
15. **One-shot reads of cold async cogs:** settled on August 12, 2026. A
    non-tracking peek or refresh is transient initial demand: it starts one
    run at pending without a durable lease, and ordinary `whileObserved`
    grace and release apply. See "Never-read async demand?" above.
16. **Registration during a flush:** settled on August 11, 2026. The initial
    run joins the current flush's reaction tail without re-entry, after work
    already scheduled for the turn and before queued write-back turns. See
    "Reaction registration in a flush?" above.
17. **Tracked read without a UI consumer:** deferred on August 12, 2026.
    Public Observation has no current-consumer query, so the settled direct
    `cogs[...]` API cannot distinguish valid automatic UI tracking from an
    accidental action read. M2 ships no warning; actions use `cogs.peek`.
    Revisit only when a public tracking-presence API can make the diagnostic
    exact without a wrapper or private SPI. See §7.
18. **Async lifecycle surface:** settled on August 13, 2026. The only public
    lifecycle lens is `status`; the weaker `phase` lens is removed.
    `CogStatus.kind` carries pending, success, or failure while its total value
    and neighboring fields remain independently observable at the SwiftUI
    boundary. Optional success remains distinguishable without `Previous` or
    optional-valued accessors. See "Async value shape?" above.
19. **App runtime name and ownership:** settled on August 13, 2026, and
    amended on August 14, 2026 by the mechanism redesign. `Cogs` is the
    public app runtime and the object application code retains, injects,
    reads, and writes through; side effects register as mechanisms at
    bootstrap rather than through an installation API. The implementation
    context is not a second public concept. See "State graph count?",
    "Context construction?", and "Mechanism lifecycle?" above.
20. **SwiftUI binding boundary:** settled on August 13, 2026. Cog vends no
    binding helper. Application code constructs ordinary SwiftUI bindings whose
    getter uses the tracked subscript and whose setter calls a domain operation.
    `commit(_:to:name:)` is the compact single-source form; the writer form
    remains the multi-write primitive. See §3.4 and §4.
21. **Refresh completion:** settled on August 13, 2026. `refresh` returns a
    `CogRefresh` whose outcome follows exactly the generation that call
    started: success, failure, superseded, or released. It never drifts to a
    later generation. See "Default async policy?" above.
22. **Controllable time:** settled on August 13, 2026. `CogTesting.TestClock`
    is the reusable test-time implementation for application scheduling and
    Cog-owned lifetime grace. It supports concurrent deadline sleeps and
    bounded acknowledgement that work has scheduled its next sleep. See
    "Testing posture?" above.
23. **State declaration names:** settled on August 14, 2026. One keyless value
    reference ends in singular `Cog`; a box ends in plural `Cogs`; narrower
    qualifiers precede that suffix. The runtime stays `cogs`, and values read
    from it keep ordinary domain names. See §3.1 and "Identity and names?"
    above.
24. **Read unwrapping:** settled on August 14, 2026. Application code binds
    each graph read to the declaration's unsuffixed domain name before using
    it. A full `CogStatus` follows the same rule rather than adding `Status`;
    reading fields from the local preserves field-level SwiftUI Observation.
    See §3.1.
25. **SwiftUI context access:** settled on August 14, 2026. The app installs
    its retained runtime above every scene, and each view that interacts with
    Cog resolves `\.cogs` itself. Views never accept, store, or forward `Cogs`;
    intermediate views pass domain values and identities only. Tests and
    previews install their isolated context through the same modifier. See
    §2.3 and §3.4.
26. **Mechanisms:** settled on August 14, 2026. Side effects bundle into
    first-class `Mechanism` values specified only at
    `Cogs.bootstrapApp(mechanisms:)`. Reactions and tasks register through a
    curated `MechanismController` — never raw `Cogs` — shorter lifetimes are
    state-gated `whenever` scopes, and ops moved to `CogOps` extensions.
    The runtime retains supplied mechanism values and cancels their scopes
    before releasing them; delegate work uses weak controller callbacks that
    become inert at scope teardown. The public
    `run`/`watch`/`EffectGroup`/`ReactionToken` surface was withdrawn. This
    replaces the effects-struct `install(in:)` convention. See "Mechanism
    lifecycle?", "Mechanism controller?", and "Op, transaction, or turn?"
    above.
27. **Lint tooling:** settled on August 17, 2026 after two `/vette` reviews.
    [lint.md](./lint.md) specifies a standalone syntax-only `coglint`,
    developed in this repository as a nested `swift/Lint` package under the
    same isolation gate as `swift/Benchmarks` and delivered as a prebuilt
    binary behind SwiftPM build-tool and command plugins. The first six rules
    enforce declaration suffixes, no `Cogs` through view initializers,
    primitives only in `CogOps`, initial app state through a mechanism,
    private writable sources, and no multi-read value helper on `Cogs` or
    `CogOps`. Classification combines written nominal types with initializer
    evidence, so an explicit type plus `.init` is not an accidental evasion;
    the multi-read rule stays lexical instead of becoming a data-flow engine.
    Cog, `coglint`, and the rule articles in `Cog.docc` share one version and
    release. V1 vends the plugins from the root manifest unless a measured
    unused-artifact cost selects a distribution-only manifest repository;
    that fallback remains generated, version-coupled, and published only
    after the matching rule pages. Product names, severities, the stable URL
    shape, later rules, and Kotlin timing remain open. Concept record: issue
    #318.

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
