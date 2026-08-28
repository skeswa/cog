# Cog for Swift: core design

_August 9, 2026_

_See [README.md](../README.md) for the document map._

Cog is a state library for SwiftUI. A change updates only the automatic values
and views that used it. Observation handles the UI edge; Cog owns the graph.
[rx.md](./rx.md) holds §5.4, and [mechanisms.md](./mechanisms.md) holds §6.

The [shared state model](../../design.md) defines cross-platform terms and
rules. This file defines the Swift API and behavior.

The MainActor gives Cog one ordered lane. Observation lets SwiftUI track single
values. Access control limits writes. Cog adds cached automatic state,
consistent turns, keyed boxes, and async policies.

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
| Cached automatic values                  | Nothing; computed properties run on every read.                                                 |
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

Default isolation makes top-level cogs MainActor values. `@concurrent` moves
expensive work to the global executor. Task names improve Instruments output.
Newer APIs such as `Task.immediate`, cancellation shields, and `~Sendable`
improve edges but do not change the graph.

A separate actor would be re-entrant at each `await`. Locks would allow torn UI
reads and require `Sendable` values. Move only expensive computation off main
(§2.5, Appendix C).

### 1.3 The ecosystem leaves room for Cog

Existing libraries cover parts of this design. swift-state-graph has cached
values and Observation. swiftui-atom-properties has keyed and async atoms.
TCA covers a much larger architecture. Cog stays focused on one small graph,
explicit turns, keyed state, and async state.

Cog follows the common push-pull graph model: writes mark possible changes,
reads compute only what they need, and equal results stop more work. Appendix B
links the sources.

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
│ State, automatic values, turns, async work, reactions. │
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
- An **automatic cog** computes a value from other cogs.
- A **state** is one source or automatic value in the app `Cogs`, or in the
  one isolated context of a test or preview runtime.
- A **turn** is one outermost call to `turn` and the work it causes.
- A **hot root** has a live UI, reaction, or stream consumer. A cold state does
  not.

A correct normal read includes all writes from the latest finished turn.
Outside data may still be loading; `CogStatus` shows that. A `Writer` read sees
the current turn's staged values, so read-modify-write stays correct.

Cog does not recompute the whole graph after a write. It marks possible changes
and computes a value only when a consumer needs it. Parents settle first.
Equality stops the wave when a value stayed the same.

At turn end, Cog publishes changed sources, marks children, settles hot roots,
notifies UI and streams, and runs reactions in order. Cold branches stay lazy.
§3.2 gives the exact order.

Each outer `turn` call has its own name and history record, even when two calls
run in one event handler. Stream buffers may still combine values (§8).

Only the `Writer` passed to `turn` can write. Cog flushes when the outer body
ends. Nested turns join it. A saved writer fails after its turn ends.

### 2.3 Descriptors name state; `Cogs` stores it

A top-level declaration is a name, not global state. One app `Cogs` stores each
descriptor and optional key. Each test or preview has its own isolated `Cogs`.
This supports keyed boxes, one app graph, clean tests, and one history.

Production code must not create child contexts. Truly view-local state stays
in SwiftUI `@State`. Cog-backed screen state lives in the app graph, keyed by
a screen identity when needed, and resets through an explicit op. One mutable
domain fact gets one manual source; another feature may read it or compute a
new shape automatically, but must not mirror it into a second
`Cog<Value>.Manual`.

The plain `Cogs` initializer is package-only. Production calls
`Cogs.assemble(mechanisms:)` once; a second call fails in every build. Tests
and previews use `Cogs.forTesting(seeding:mechanisms:)` for a fresh context.
It seeds first, then starts mechanisms, and never claims the production slot.

The app retains the value from `assemble` and injects it above every scene.
Each Cog-using view resolves `\.cogs` itself; no view accepts or forwards the
runtime. Non-view composition points may receive it directly. Ops extend
`CogOps`, so both `Cogs` and mechanism controllers use them. There is no global
`Cogs.app`.

Tests of production setup use a synchronous MainActor `CogTesting` fixture. It
calls real assembly and clears the global slot in `defer`. It cannot suspend,
so parallel tests cannot see the temporary install. Test-only checks may
compare context identity but cannot inspect graph storage.

An internal final-class descriptor has stable `ObjectIdentifier` identity.
Public value references carry that descriptor and, for a box, a key. A keyless
declaration creates one descriptor. `box[key]` creates no new descriptor and
allocates nothing. Human labels use `name:` or `fileID:line`; object IDs stay
internal.

Selectors and reactions read with `c[valueReference]`. UI code reads with
`cogs[valueReference]`. `peek` is the clear non-tracking form. A `Writer`, also
named `c`, uses the same subscript to see and stage its turn's values.

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
Keep small automatic values on main and use `@concurrent` work in a
`Cog<Value>.Async` for expensive computation. Network, database, and sensor producers can work
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

Names show the state shape. A keyless declaration ends in `Cog`; a box ends in
`Cogs`. Put a narrower role first, as in `weatherServiceLoaderCog`. A manual
declaration begins with a leading underscore, and its `.readOnly` projection
takes the same name without the underscore, so the clean name is the one the
rest of the app reads. The runtime local is `cogs`. A value read from the graph
uses a normal domain name.

Bind each graph read to that plain name before using it. This keeps references,
values, and read order visible:

```swift
let someWords = cogs[someWordsCog]
let anotherThing = cogs[anotherThingCogs[someWords]]
let hereIsAnother = cogs.status[hereIsAnotherCog]
```

This applies in views, selectors, reactions, ops, and peeks. A status local also
uses the plain domain name; its `CogStatus` type shows the difference. Binding
the status tracks no field until code reads one. Writer targets and `refresh`
arguments stay direct because they are references, not read values.

```swift
// WeatherState+Cogs.swift

private let _weatherServiceCog = Cog<WeatherService>.Manual { .live }
let weatherServiceCog = _weatherServiceCog.readOnly

private let _weatherReportCogs = CogBox<Weather?, ZipCode>.Manual { nil }
private let _heatAdvisoryCogs = CogBox<Bool, ZipCode>.Manual { false }
private let _currentZipCog = Cog<ZipCode?>.Manual { nil }

let weatherReportCogs = _weatherReportCogs.readOnly
let heatAdvisoryCogs = _heatAdvisoryCogs.readOnly
let currentZipCog = _currentZipCog.readOnly

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

| Declare             | Example                                    | Read                                             |
| ------------------- | ------------------------------------------ | ------------------------------------------------ |
| One automatic value | `Cog<Bool> { ... }`                        | `c[valueReference]` → `Bool`                     |
| An automatic box    | `CogBox<Bool, ZipCode> { ... }`            | `c[box[zip]]`                                    |
| One source          | `Cog<ZipCode?>.Manual { nil }`             | Read normally; write `c[valueReference] = zip`   |
| A source box        | `CogBox<Weather?, ZipCode>.Manual { nil }` | `c[box[zip]] = report`                           |
| One async value     | `Cog<Forecast?>.Async { ... }`             | `c[valueReference]` → `Forecast?`                |
| An async box        | `CogBox<Weather?, ZipCode>.Async { ... }`  | `c[box[zip]]`; status via `c.status[...]` (§5.1) |

Four rules keep the API consistent:

1. **Runtime APIs take value references.** `Cog<T>` is readable;
   `Cog<T>.Manual` is also writable. Descriptor plus key gives identity.
2. **Boxes create references.** `box[key]` returns one. A keyless declaration
   is already bound to its only state.
3. **Production kind does not change the read type.** Manual, automatic, and
   async describe how a value is made. Each normal read returns `T`; async
   lifecycle uses `status` (§5.1).
4. **Common calls stay short.** Use `c[...]`, `turn`, and `box[key]`. Use the
   longer `peek` only for an untracked read.

Keyed references use inline `AnyHashable?`; the public type is not `@frozen`.
Interned and generic-key designs lost the keyed benchmarks and were removed.
See perf §4 and §9.6.

Keys pass through normal lexical capture, as `zip` does above — there is no
hidden key flow. States appear lazily per descriptor and key. A manual box's
starting value may also be a key-based closure.

Every starting value and async default is written as a closure, never as a bare
value. A declaration is one immutable descriptor shared by every state it ever
names — across contexts, across a box's keys, and across a `whileObserved`
state released and recreated. A bare value would be captured once and handed to
all of them, so a `Value` that is or contains a reference type would give an
app, each of its tests, and every key of a box the same object to mutate. The
closure moves the value's construction to the moment a state is created, which
is the only place it can be per-state. Cog calls it once per state and never
again, so it must be cheap and free of side effects; it receives no `Reader`
and creates no dependencies. A manual box's closure may take the key, and
`{ 0 }` costs nothing extra when `Value` has value semantics anyway.

### 3.2 Ops and turns

```swift
extension CogOps {
    func checkWeather(_ zip: ZipCode) async throws {
        let service = peek(weatherServiceCog)

        async let report = service.weather(for: zip)
        async let advisories = service.advisories(for: zip)
        let (r, a) = try await (report, advisories)

        turn { c in
            c[_weatherReportCogs[zip]] = r
            c[_heatAdvisoryCogs[zip]] = a.contains { $0 is HeatAdvisory }
        }
    }

    func selectCurrentLocation(_ zip: ZipCode) {
        turn(_currentZipCog, to: zip)
    }
}
```

`turn` is the only write entry point. Its scalar overload handles the common
one-source operation; the writer overload groups related writes into one turn.

- Only `Writer` can change a source. It supports read and write, so
  `c[countCog] += 1` works.
- Each writer carries an unforgeable turn ID and checks that its context is
  still accumulating that turn. An escaped writer cannot be used later.
- `#function` names the turn without extra code. An op is just a normal
  method that calls `turn`, written in an extension of `CogOps` — the
  small protocol carrying `turn`, `peek`, and `refresh` that both `Cogs`
  and a mechanism's controller adopt. One definition serves views, app code,
  and mechanisms; pass a custom name only when needed.
- Access control decides which source value references the method may name (§4).

A context has three phases:

1. **Idle:** an outer turn starts a turn.
2. **Accumulating:** turn bodies stage writes. Nested turns join the same
   turn and turn ID.
3. **Flushing:** the outer body has returned. A new turn now waits in a FIFO
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

A reaction first runs to record dependencies. It runs again after one changes,
always against settled state. Mechanisms register reactions with `m.run` or
`m.watch`, so each has a named owner (§6.2–§6.3).

Outside a flush, the first run finishes before registration returns. During a
flush, it joins the reaction queue after work already scheduled and before
queued write-back turns. It never re-enters the registering reaction. A
reaction ends with its app or `whenever` scope; there is no public handle.

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

The subscript calls the state's registrar, so SwiftUI tracks the exact
descriptor and key. The app installs one `Cogs` above each scene. Every view
that uses Cog declares `@Environment(\.cogs) private var cogs`; views pass
domain values and IDs, not the runtime. Tests and previews install an isolated
context with the same modifier.

SwiftUI does not report when it stops watching a registrar. A state that
reaches the UI boundary therefore stays pinned to the app context (§5.3).

Sources are `private`, so views cannot name writable references. A bindings
file may export an ordinary SwiftUI adapter when a control requires `Binding`:

```swift
// WeatherState+Cogs.swift
extension CogOps {
    func selectCurrentLocation(_ zip: ZipCode?) {
        turn(_currentZipCog, to: zip)
    }
}

// WeatherState+Bindings.swift
extension Cogs {
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
does not vend binding helpers. The single-source `turn(_:to:)` overload keeps
that operation compact while preserving `turn` as the only write boundary.
Multi-source and read-modify-write operations keep the writer form. For a
one-time untracked read, use `cogs.peek(...)`.

---

## 4. Write ownership

Swift access control replaces the custom lints proposed for Dart:

- Declare writable sources `private` or `fileprivate`, with a leading
  underscore on the name; both spellings are fine, and at file scope the two
  are identical (the formatter prefers `private` there). Only that file or
  type can name them.
- Expose `.readOnly` value references or automatic cogs. A projection takes
  the source's name without the underscore, so the clean name is the readable
  one.
- Put ops, UI adapters, and test seams beside the sources they may write.

Callers can use `try await cogs.checkWeather(zip)` but cannot reach
`_weatherReportCogs`. A review finds every possible write by searching one
file's `turn` closures.

`@testable import` cannot see `fileprivate` sources, so the owning file may
publish narrow debug-only source capabilities. Test support imports
`CogTesting` to seed those capabilities or calls loud turn helpers from the
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

Normal async reads are total. `c[...]` returns the latest accepted value or the
declaration's default. Code that needs request state uses the `status` lens.

There is no public `initial` kind. The first read creates the state, starts
work, and publishes `pending`, the default value, and `hasSucceeded == false`
as one turn. A status read returns those fields together. A value read returns
the same default.

`default:` is produced per state for the reason §3.1 gives, and async state
needs that more than manual state does: it defaults to `whileObserved`, so
release and recreation is its ordinary path rather than an opt-in. Cog produces
the default once when it creates a state and keeps that value for as long as the
state lives, so every pending and failure status before the first success
carries one default rather than a fresh one each time it is published.

Unlike a manual starting value, `default:` is an `@autoclosure`, so the call
site still writes `default: .empty`. The shapes differ because the call sites
do: a manual starting value is the declaration's only closure and reads well as
one, while an async declaration already ends in its selector closure — a second
one there would put two closures in a single call, which is both harder to read
and rejected by the formatter's `OnlyOneTrailingClosureArgument` rule.

Peek and refresh follow the same rule on a never-read async state: create it,
run the synchronous selector, and start one pending generation. Peek adds no
dependency, subscription, or Observation boundary. After creation, refresh
uses the policy in §5.2.

`value` always answers what the UI can show. For an optional value, `nil` with
`hasSucceeded == false` is the default; `nil` with `true` is a successful nil.
`error` is set only for the current failure. `isLoading` and `hasSucceeded` are
separate facts. V1 has no failure type parameter.

Every async declaration writes `default:`, including `default: nil`. Choose a
value that is honest during loading. Zero can be a true unread count; an empty
message list may claim knowledge the app does not have and should be optional.

An async selector is synchronous and tracked. It reads dependencies, then
returns a description of async work:

```swift
let fetchedWeatherCogs = CogBox<Weather?, ZipCode>.Async(
    .latest,
    default: nil
) { c, zip in
    let weatherService = c[weatherServiceCog]
    return .run { try await weatherService.weather(for: zip) }
}
```

This async box is an alternative to the manual weather box in §3.1. A real app
uses one source for the fact, not both.

`.run` returns one value. `.stream` publishes each changed element as a turn.
All tracked reads happen before work starts, so no dependency hides after an
`await`. A dependency change reruns the selector; §5.2 controls old work.

Read the value normally:

```swift
let fetchedWeather = c[fetchedWeatherCogs[zip]] // Weather? — total value
```

Or opt into the lifecycle through the `status` lens while keeping the same
unsuffixed domain name:

```swift
let fetchedWeather = c.status[fetchedWeatherCogs[zip]] // CogStatus<Weather?>
```

Each capability has value and status forms. At the UI edge, `kind`, `value`,
`hasSucceeded`, `error`, and `isLoading` track separately. Selectors, reactions,
and status watches track the whole status. Asking a sync cog for status is a
compile error.

An equal successful value leaves value readers quiet, though status readers see
pending and success. `refresh` returns a `CogRefresh` for its exact generation:
success, failure, `superseded`, or `released`. It never follows a later run.

Use one status read for request UI. SwiftUI tracks only the fields the body
uses. Code that needs only the value uses plain `c[...]` and stays quiet when
that value does not change.

### 5.2 Scheduling policies

| Policy              | Behavior                                                   | Common stream name           |
| ------------------- | ---------------------------------------------------------- | ---------------------------- |
| `.latest` (default) | Cancel old work; only the newest generation may publish.   | `switchMap`                  |
| `.queue`            | Run requests in order.                                     | `concatMap`                  |
| `.exhaustLatest`    | Finish current work, coalesce changes, then catch up once. | exhaust with latest catch-up |
| `.merged`           | Allow overlapping runs; each result is its own turn.       | `merge` / `flatMap`          |

Cancellation alone is not enough: old work may finish before it notices
cancellation, so every run gets a generation number, and the MainActor turns
a result only if that generation is still current.

Each visible pending, success, or failure state is a turn. Replacing cancelled
work does not publish a failure; the replaced `CogRefresh` handle resolves as
`superseded`.

A failed `.queue` run publishes failure, resolves its refresh handle, and then
starts the next request. The next pending turn keeps the last success or the
declared default.

True exhaust behavior drops events while busy. An automatic value cannot forget
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

Natural stream end publishes no turn and starts no new work. A stream that
emitted a value keeps its last success. An empty stream stays pending on its
default with `hasSucceeded == false`. A dependency change or refresh starts a
new generation. Throw an error when empty completion is not valid.

A current stream error publishes failure, keeps the last value or default, and
does not restart. An error before the first accepted element fails its refresh
handle. A later error cannot change a handle already resolved as success.
Cog-led replacement or release is silent; any error from a stream Cog did not
cancel publishes as failure.

Equal `Equatable` stream elements create no turn, notice, or history entry.
Values without equality treat every element as changed. Keep duplicate event
history in an op or reaction, not Cog state (§5.4).

### 5.3 Freshness and lifetime

A future query layer should support stale rules based on age, network return,
or app focus; tag-based invalidation across keyed boxes; a stream that yields
a disk value, then a network value; and separate clocks for freshness and
memory retention.

State lifetime depends on state kind:

- **Manual:** `.app` by default because release would lose the value. Ephemeral
  sources use `.whileObserved(resetToInitial: true, grace:)` in `lifetime:`.
  `resetToInitial: false` cannot keep its promise and fails at declaration.
  Peek and write renew grace; reactions lease; UI reads pin.
- **Sync automatic:** `.whileObserved(grace:)` by default. Cog can recompute it.
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

`whileObserved` uses the context default when grace is omitted. Production uses
30 seconds. Tests inject a shorter duration and a controlled clock.

A sync or async peek, and an async refresh, creates transient demand. It cancels
an old expiry and starts a full grace window when the call returns. Another
one-time call renews the window. A UI, reaction, or stream reader creates a real
lease. Without one, expiry releases state; async release also cancels work and
blocks late results. Work that must finish without a reader belongs in an op or
an app-lifetime declaration.

### 5.4 Where the Rx operators went

See [rx.md](./rx.md). It maps Rx behavior to dynamic dependencies, async
policies, and `.stream`, while keeping ordered event history outside the state
graph.

---

## 6. Side effects, worked

See [mechanisms.md](./mechanisms.md) for mechanisms, reactions, gated scopes,
assembly registration, view lifetime, testing, background work, and
reconciler rules.

---

## 7. What the SwiftUI boundary must handle

- **Reads in escaping closures are not tracked.** A `Button` action or `Task`
  uses `cogs.peek`. Public Observation cannot tell Cog whether a subscript has
  an active UI reader, so Cog cannot issue an exact warning. Do not use private
  API or guesses.
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

- **External `@Observable` input:** `c.track(model, \.name)` links outside
  state into Cog. After a mutation propagates, dependents see its newest value;
  several mutations may combine. iOS 26 `Observations` defines the boundary.
  Older systems re-arm `withObservationTracking` after the setter. A small gap
  remains before re-arm, so one extra mutation may be missed.
- **Exports:** `cogs.values(of:buffering:)` starts with the current value.
  `.newest(1)` may skip turns for a slow reader. `.oldest(n)` keeps the oldest
  waiting values and drops newer ones while full. `.unbounded` keeps all
  values. No policy blocks a turn. Each subscriber owns a graph lease.
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

Use four tests for a new choice: Is normal app code easy to read? Are reads
correct? Does the app keep one source of truth? Do measurements show less work?

### Settled choices

| Area                 | Decision                                                                                                                                                                                                                                                                                               |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Writes               | Sources are `private` or `fileprivate` and expose `.readOnly`. A `Writer` is valid only for its turn. Named methods on `CogOps` wrap `turn` and `refresh`.                                                                                                                                             |
| State names          | A descriptor plus optional key names state. Keyless declarations end in `Cog`; boxes end in `Cogs`. A manual declaration begins with `_`, and its `.readOnly` projection takes the same name without the underscore. Read values use plain domain names.                                               |
| Starting values      | Every manual starting value and async `default:` is produced once per state, never stored on the shared descriptor. Manual takes an explicit `@MainActor` closure; async takes an `@autoclosure` and materializes it at state creation.                                                                |
| Keyed API            | Boxes make value references. Keys use inline `AnyHashable?`. Public reference types stay resilient.                                                                                                                                                                                                    |
| Dependencies         | Actual reads rebuild edges on each run. A shared linked pool stores edges. CLEAN, CHECK, DIRTY, versions, and equality stop unneeded work.                                                                                                                                                             |
| Shipping core        | The specialized arena with pool edges is the default and only shipping core. `CompactArena` turns off the typed frontier to reduce binary size.                                                                                                                                                        |
| Correctness          | Reads use lazy pull. Hot roots settle before notices. Cycles and turns during automatic computation fail with a keyed path.                                                                                                                                                                            |
| Async values         | A value read returns the latest success or required default. The `status` lens exposes pending, success, failure, value, error, and flags. There is no public initial state.                                                                                                                           |
| Async work           | `.latest` is the default. `.queue`, `.merged`, and `.exhaustLatest` apply to one-shot work. Streams use `.latest` only. Generations reject late results.                                                                                                                                               |
| Stream end and error | Natural end publishes no turn. A current thrown error publishes failure. Cog-led cancellation is silent. Equal elements are no-ops when equality exists.                                                                                                                                               |
| Refresh result       | `CogRefresh` reports success, failure, superseded, or released for the exact generation it started.                                                                                                                                                                                                    |
| Lifetime             | Manual and UI-bound state live for the app by default. Automatic and async state use `whileObserved`. Production grace is 30 seconds.                                                                                                                                                                  |
| Mechanisms           | Assembly owns app-wide effects. `whenever` owns gated work. Controllers expose ops but not raw `Cogs`. Reaction writes queue as later turns.                                                                                                                                                           |
| UI and exports       | Views resolve `\.cogs` themselves. Bindings use a tracked getter and named-op setter. Exports never block a turn.                                                                                                                                                                                      |
| Runtime creation     | Production calls `assemble(mechanisms:)` once. Tests and previews call `forTesting(seeding:mechanisms:)`. There is no ambient app runtime.                                                                                                                                                             |
| Tests                | Tests use public APIs, injected clocks, continuations, exact handles, and named diagnostic hooks. A production-install fixture is synchronous and scoped. `CogTesting` ships the async harness: `ControlledWork`, `ControlledStream`, `Cogs.forTestingWithController`, and `TestClock` sleeper counts. |
| Traps and deinits    | Clear release-build traps use `fatalError`. Every generic class writes `nonisolated deinit` until the Swift optimizer bug is fixed.                                                                                                                                                                    |
| Public names         | The shape families use `Cog<Value>.Manual` / `.Async` / `.Projection` and the corresponding `CogBox<Value, Key>` members. `ManualCogLifetime` stays top-level. [prior-art.md](./prior-art.md) records the naming review and the `Cogs` revisit trigger.                                                |
| Lint                 | `coglint` enforces the eight usage rules. [lint.md](./lint.md) defines its package, plugins, errors, and release pins.                                                                                                                                                                                 |
| Storefront gates     | Two cuts earn CI thresholds: interactions (exact 12 mallocs, 600 µs ceiling) and the compute control (exact 5,611 mallocs, 1.7 ms ceiling). They commit only after a pinned-runner session reproduces them. The other cuts stay report-only; the phase-split probe owns cold-start attribution.        |

The benchmark record holds the old core and layout comparisons. This table
states only the current result.

### Stable issue IDs

Other docs cite these numbers. Keep an ID even after its question is settled.

1. **Read spelling — settled.** Use `c[...]` in selectors and reactions,
   `cogs[...]` at the UI edge, and `peek` for one-time reads.
2. **First-class `Op` values — open.** Plain `CogOps` methods ship today.
3. **Deferred reactions — open.** Synchronous ordered reactions ship today.
4. **App assembly — settled.** Production uses `assemble`; tests and
   previews use `forTesting`. `assemble` replaced `bootstrapApp` with no
   deprecated alias, and API names reference the `Cogs` object rather than
   the "app" — hence `withAssembledCogs`, `isAssembledCogs`, and
   `hasAssembledCogs`.
5. **Debug-history UI — open.** The bounded data exists; its display does not.
6. **Dart and Flutter feedback — later.** Revisit after the Swift model proves
   useful in shipped apps.
7. **Persistence helpers — open.** Durable code writes the store first and the
   graph second. `PersistedCog` is not designed.
8. **Stream termination — settled.** Natural end keeps the last status and
   starts no work.
9. **Stream failure — settled.** A current error publishes failure; Cog-led
   cancellation stays quiet.
10. **Queue failure — settled.** A failed run publishes and resolves, then the
    next queued request starts.
11. **Writes during automatic computation — settled.** They fail before the
    turn body runs.
12. **Scope cancellation — settled.** Public effect groups were removed.
    Internal scope cancellation is final and safe to repeat.
13. **Debounce and throttle — open.** They belong at a reaction or async edge,
    not in graph basics.
14. **Equal stream elements — settled.** Equal values make no turn. Event
    history stays outside Cog.
15. **Cold async one-time reads — settled.** Peek or refresh starts one pending
    run as transient demand.
16. **Registration during flush — settled.** The first run joins the current
    reaction tail without re-entry.
17. **Missing UI consumer warning — deferred.** Public Observation cannot tell
    whether a tracked UI consumer exists.
18. **Async lifecycle API — settled.** `status` is the only lifecycle lens.
19. **Runtime name and ownership — settled.** `Cogs` is the app-owned runtime.
20. **SwiftUI bindings — settled.** Cog ships no binding helper; the
    `tracked-binding-adapters` lint rule enforces the adapter shape instead.
21. **Refresh completion — settled.** The handle follows one generation.
22. **Test time — settled.** `CogTesting.TestClock` controls app scheduling and
    Cog grace periods.
23. **Declaration names — settled.** Keyless names end in `Cog`; boxes end in
    `Cogs`.
24. **Read locals — settled.** Bind each read to its plain domain name.
25. **SwiftUI runtime access — settled.** Each Cog-using view reads `\.cogs`
    from the environment.
26. **Mechanisms — settled.** Assembly lists them; controllers register work;
    state gates own shorter scopes.
27. **Lint tooling — settled.** The syntax-only linter, eight rules, plugins,
    docs, and sibling distribution ship together.
28. **Shape-family spelling — settled.** The automatic shape remains
    `Cog<Value>`; manual, async, and projection shapes are nested as
    `Cog<Value>.Manual`, `.Async`, and `.Projection`, with the same members on
    `CogBox<Value, Key>`. `.Manual` preserves the manual/automatic mechanism
    axis. `ManualCogLifetime` remains top-level because it is value-independent
    and shared by both shape families. The former prefixed shape names are
    removed, not retained as deprecated typealiases.
29. **Underscored manual names — settled.** A manual declaration begins with a
    leading underscore, whether or not it is projected, and its `.readOnly`
    projection takes exactly the same name without the underscore, so a source
    and its published reference read like
    `private let _weatherServiceCog = Cog<WeatherService>.Manual { .live }` and
    `let weatherServiceCog = _weatherServiceCog.readOnly`. This replaces the
    former `Source` role qualifier, which is retired. The
    `manual-cog-underscore` lint rule enforces both halves.
30. **Starting values are per state — settled.** A manual starting value and an
    async `default:` are produced once per state rather than stored on the
    shared descriptor, so a reference-type value cannot be shared by two
    contexts, by two keys of one box, or by a `whileObserved` state across a
    release. Manual takes an explicit `@MainActor` closure —
    `Cog<Int>.Manual { 0 }` — and its bare-value initializers were replaced
    outright rather than joined by an overload, because leaving the hazardous
    spelling as the shorter one defeats the change. Async takes an
    `@autoclosure` instead, keeping `default: .empty` at the call site: an async
    declaration already ends in its selector closure, and a second closure there
    reads worse and trips the formatter's `OnlyOneTrailingClosureArgument` rule.
    The two shapes are spelled differently because their call sites are shaped
    differently, not because their semantics differ.

---

## 11. Implementation status

The original spikes are complete:

1. The class-based correctness core proved behavior and is now a saved
   benchmark baseline.
2. Observation boundaries, the Weather app, UIKit checks, and the isolation
   matrix are implemented.
3. The benchmark port covers diamond, deep, broad, unstable, keyed, and churn
   shapes with run-count checks.
4. The public-name review is complete.
5. The specialized arena replaced the simple core after the shared-cost and
   typed-frontier work passed the same behavior suite.
6. Async runs, policies, streams, exports, lifetime, and safe late-result
   rejection are implemented.

The [performance record](../impl/perf.md) owns measurements.

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
whole SwiftUI render atomic: the graph could turn between two view reads.
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

## Appendix D: other design inputs

- swiftui-atom-properties informed keyed and async state, scopes, and release.
- TCA sets a useful upper limit on setup and macro cost.
- `AsyncSequence`, `share`, and `flatMapLatest` cover streams without Combine.
- Query systems suggest tag invalidation and separate freshness and retention.
- Common Observation problems include uncached computed values, equal-write
  notices, whole-collection tracking, and view-owned state lifetime.
- Reactively and alien-signals supply the push-pull graph model.
- `.latest` is safer for UI state than an ordered default because old work cannot
  overwrite new state.

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
