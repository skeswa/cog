# Cog for Swift: mechanisms and background work

_August 14, 2026_

This file is §6 of [exploration.md](./exploration.md). It covers mechanisms —
the home for every side effect — their bootstrap, gating, testing, and work
that can outlive the app process. Other section numbers point to the core
file. The state-versus-effect boundary comes from the
[shared state model](../../design.md); this file owns its Swift lifecycle and
API.

## 6. Side effects, worked

A side effect changes something outside the graph: alerts, haptics, logs,
files, system services. Work that only computes graph state is not a side
effect. A **mechanism** watches cogs and performs that outside work. It
bundles the dependencies a family of effects needs — services, clocks,
notifiers — with the reactions and tasks that use them, and it is the only
place reactions and tasks exist. Keeping that boundary clear makes application
behavior easy to find: every imperative consequence of state lives in a named
mechanism registered at bootstrap.

### 6.1 Choosing a home for a side effect

| Need                                  | Use                                                 |
| ------------------------------------- | --------------------------------------------------- |
| Compute state from other state        | `AsyncCog` (§5.1), or an op that writes manual cogs |
| Send something outside the graph      | A reaction inside a mechanism                       |
| Respond to a user action              | Op (§3.2)                                           |
| Run for the app lifetime              | A mechanism registered at bootstrap                 |
| Run for a shorter domain lifetime     | A `whenever` scope inside a mechanism (§6.2)        |
| Live only while one screen is visible | SwiftUI `.task` and a `values` stream (§6.5)        |
| Continue after process death          | Durable state, an engine, and a reconciler (§6.7)   |

For example, “check the weather when the ZIP changes” produces state, so it
belongs in the `fetchedWeatherCogs` async box from §5.1. “Alert me when the
weather becomes nice” leaves the graph, so it is a reaction inside the weather
mechanism.

### 6.2 Mechanisms

A mechanism is any type conforming to one small protocol:

```swift
@MainActor
public protocol Mechanism {
    /// Names this mechanism in debug history, task names, and diagnostics.
    /// Defaults to the type name with a trailing "Mechanism" dropped.
    var name: String { get }

    /// Registers this mechanism's reactions, tasks, and gated scopes.
    /// Called exactly once, during bootstrap, in array order.
    func operate(_ m: MechanismController)
}
```

Structs and classes both conform; dependencies are ordinary stored properties.
A struct fits a stateless mechanism, while a class fits one that owns a
connection or other reference-typed resource. The runtime retains the exact
mechanism values supplied at bootstrap alongside their registration scopes.
During runtime teardown, it cancels every scope first and releases the retained
mechanism values only afterward, so a class-owned resource cannot disappear
while one of its reactions or tasks is still registered.

```swift
// WeatherMechanism.swift

struct WeatherMechanism: Mechanism {
    var notifier: Notifier
    var clock: any Clock<Duration> = ContinuousClock()

    func operate(_ m: MechanismController) {
        m.watch(isNiceOutsideHereCog, initial: .skip,
                name: "niceAlert") { was, nice in
            if nice && !was {
                notifier.alert("It is nice outside!")
            }
        }

        m.task(name: "hourlyRefresh") { [weak m] in
            while true {
                try await clock.sleep(for: .seconds(3_600))
                guard let m else { return }
                await m.refreshCurrentLocation()
            }
        }
    }
}
```

The controller `m` is the mechanism's entire relationship with the graph, and
its pieces have narrow jobs:

- `m.watch` registers a reaction on one cog and receives its old and new
  values. `.skip` avoids an alert during bootstrap. `m.run` registers a
  reaction over several dependencies; it runs once during registration to
  record them (§3.3).
- `m.task` starts a normal unstructured Swift task owned by the mechanism's
  scope.
  Time-based work injects a `Clock` so tests control it. Task bodies call ops,
  so writes keep useful names in debug history. A long-running body captures
  its controller weakly and promotes it around each unit of graph work;
  this lets scope teardown release the controller even if cancelled work has
  not cooperatively returned yet.
- `m.peek` makes an untracked read (§2.4); an `operate`-time read never
  becomes a dependency, because `operate` is registration, not a reaction.
- Ops are available on `m` directly, because ops extend `CogOps` and
  the controller conforms (§3.2). `m.turn` and `m.refresh` are the
  primitives beneath them.
- Every registration is attributed. `watch`, `run`, and `task` names compose
  under the mechanism's `name` — the task above appears as
  `Weather.hourlyRefresh` in debug history and Instruments — and a turn an op
  opens through `m` records which mechanism asked for it.

There is deliberately no raw `Cogs` on the controller. A mechanism that could
reach the runtime could also leak it past its own discipline; routing every
act through `m` is what makes attribution and isolated testing exact.

`MechanismController` is a final-class lifetime capability retained by its
scope, so asynchronous and delegate-driven work may capture it weakly. It does
not own the app runtime. When its scope ends, the runtime cancels the scope's
registrations and tasks and releases the controller. Work that can outlive that
scope installs a `[weak m]` callback and returns when promotion fails; storing a
controller strongly in an external engine is unsupported because it would let
the engine outlive the lifetime that authorized its graph access. The same
rule applies to a sub-controller from `whenever`: after the gate falls, an
external callback weakly holding that sub-controller becomes inert.

**Gated scopes.** A lifetime shorter than the app is graph state, not a
registration ceremony. `whenever` runs a nested scope while a Bool cog is
true:

```swift
func operate(_ m: MechanismController) {
    m.whenever(isLoggedInCog, name: "session") { s in
        s.watch(pendingUploadsCog, initial: .run) { _, uploads in
            sync.enqueue(uploads)
        }
        s.task(name: "heartbeat") { [weak s] in
            while true {
                try await clock.sleep(for: .seconds(30))
                guard let s else { return }
                await s.sendHeartbeat()
            }
        }
    }
}
```

Its rules:

- The gate is the scope's only tracked dependency. When the gate reads true —
  at registration or after a later turn — the body runs once with a fresh
  sub-controller and its registrations become live.
- When a turn settles the gate to false, everything registered through that
  sub-controller ends: reactions unregister and tasks cancel. The scope's
  teardown replaces a reaction run in the ordinary flush order (§3.2), so
  effects never observe a half-closed scope.
- The next rise runs the body again from scratch. Nothing survives a
  down-and-up cycle; a scope that needs continuity keeps it in graph state.
- The body itself is not a reaction. Reads inside it other than through its
  own `watch`/`run` registrations use `s.peek` and never re-trigger the
  scope.
- Scopes nest: a sub-controller offers the full controller surface, including
  `whenever`, and names continue to compose (`Session.heartbeat` above
  becomes `Weather.session.heartbeat` when nested under `session`).

`whenever` replaces every scoped-ownership object the design previously
needed. There is no public effect group or reaction token: app lifetime comes
from bootstrap, and every shorter lifetime is a gate expressed in state.

### 6.3 Bootstrap-only registration and lifecycle

Mechanisms are specified when the app runtime is bootstrapped, and nowhere
else:

```swift
@main
struct WeatherApp: App {
    @State private var cogs: Cogs

    init() {
        let cogs = Cogs.bootstrapApp(mechanisms: [
            WeatherMechanism(notifier: .live),
        ])
        _cogs = State(initialValue: cogs)
    }

    var body: some Scene {
        WindowGroup { RootView().cogEnvironment(cogs) }
    }
}
```

`bootstrapApp(mechanisms:)` constructs the runtime, then calls each
mechanism's `operate` synchronously in array order, and only then returns.
The consequences are deliberate:

- **When bootstrap returns, every mechanism is live.** There is no window in
  which the app runs without its effects, no lazy registration that depends
  on accidental first access, and no late installation API to reopen that
  window. A mechanism a feature forgets to list simply never runs, which a
  test catches immediately.
- **Order is exact.** Cross-mechanism reaction order is array order, because
  reactions run in registration order (§3.3). Writes made during `operate`
  `turn` as ordinary named turns and settle before bootstrap returns, so a
  mechanism may seed demand — `m.refresh(...)` — or configure state, and a
  later mechanism observes the result.
- **Names are enforced.** Two mechanisms with the same `name` fail fast with
  a clear error in debug and release builds, because attribution and
  history depend on the name being unambiguous.
- **Reactions have one door.** `run`, `watch`, and task ownership are
  controller capabilities only; the public `Cogs` surface has no reaction,
  watch, or effect-group API. Registration handles stay internal: the runtime
  owns each mechanism's scope, cancellation of a scope is terminal and
  idempotent, and an isolated test context tears every scope down when it
  deinitializes.

The `App` creates this runtime once and shares it across every scene. The
root installs the runtime into SwiftUI once. Every descendant view that
interacts with Cog resolves `@Environment(\.cogs)` for itself; views never
accept or forward `Cogs` through their initializers. Intermediate views pass
domain values and identities, while explicit runtime parameters remain at
non-view composition boundaries — the mechanism list above, and isolated test
harnesses (§2.3).

### 6.4 Writing back into the graph

Reactions may cause writes, but never into the turn they are flushing:

1. The outer `turn` call settles state.
2. Reactions run synchronously, in registration order, against that settled
   state.
3. A reaction receives only a read controller. To write, it calls an op or
   another API that opens `turn`.
4. That turn waits in a FIFO queue and becomes a new turn after the current
   flush. Nested turns during the earlier accumulating phase still join the
   current turn (§3.2).

An old captured writer also fails its turn-ID check, and async writes
naturally start later turns because they happen after an `await`.

Mechanisms can still form a loop: turn → reaction → turn. A debug guard
should warn after about 64 turns without reaching idle and print the causal
chain, naming the mechanisms involved. The queue prevents re-entrant graph
writes; the trace makes a runaway loop clear. An internal diagnostic seam
lets tests capture the warning without scraping logs. The guard test uses a
finite reaction chain that crosses the threshold and then stops, so
warning-only behavior remains testable without an infinite drain.

Synchronous reaction flush is deliberate: tests can assert effects on the
line after an op returns, and a short background task knows its reconciler
finished before its deadline. A future `.deferred` mode may offer next-tick
coalescing, but only as an opt-in.

### 6.5 View-scoped effects

SwiftUI should own an effect that is useful only while one screen is visible:

```swift
struct WeatherMapScreen: View {
    @Environment(\.cogs) private var cogs
    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $camera)
            .task {
                for await fix in cogs.values(of: locationFix) {
                    guard let fix else { continue }
                    withAnimation { camera = .region(.around(fix)) }
                }
            }
    }
}
```

When the view disappears, `.task` cancels the sequence and its graph lease.
`values` starts with the current settled value; its default `.newest(1)`
buffer may skip intermediate turns for a slow screen, which is right for
camera state.

The test: if the lifetime is exactly one screen's visibility, use SwiftUI
lifecycle. App-wide work such as notifications and analytics belongs in a
mechanism, gated with `whenever` when it should not always run. One effect
should not use both.

### 6.6 Testing mechanisms

Writable sources are `private` or `fileprivate`, so even `@testable import`
cannot reach them. The owning state file exposes only narrow, debug-only seed capabilities
and any loud domain helpers:

```swift
// WeatherState.swift
#if DEBUG
let currentZipSeedTargetCog = currentZipSourceCog
let weatherSeedTargetsCogs = weatherReportSourceCogs

extension CogOps {
    func stubWeather(_ report: Weather?, zip: ZipCode) {
        turn { c in c[weatherReportSourceCogs[zip]] = report }
    }
}
#endif

// WeatherTestSupport.swift
import CogTesting

extension Cogs {
    func seedCurrentZip(_ zip: ZipCode?) {
        seed(currentZipSeedTargetCog, to: zip)
    }

    func seedWeather(_ report: Weather?, zip: ZipCode) {
        seed(weatherSeedTargetsCogs[zip], to: report)
    }
}
```

`seed` comes from `CogTesting` and is quiet: no turn, history record, UI
notice, or reaction. `turn` is loud and runs a real named turn. The feature
chooses its exact test surface instead of exposing all source value
references or linking test setup into the app target.

An isolated context takes its mechanisms the same way production does, with
one addition: a seeding phase that runs after the context exists and before
any `operate`, so a test arranges state first and then watches mechanisms
come alive against it:

```swift
@Test func alertsWhenTheWeatherTurnsNice() async throws {
    let notifier = Notifier.recording()
    let clock = TestClock()
    let cogs = Cogs.forTesting(
        seeding: { cogs in
            cogs.seedCurrentZip(zip)
            cogs.seedWeather(.cloudy(60), zip: zip)
        },
        mechanisms: [WeatherMechanism(notifier: notifier, clock: clock)]
    )
    #expect(notifier.alerts.isEmpty)

    cogs.stubWeather(.clear(75), zip: zip)
    #expect(notifier.alerts == ["It is nice outside!"])

    try await clock.waitForScheduledSleep()
    clock.finish()
}
```

A timer-specific test waits for `waitForScheduledSleep()` before every clock
advance, awaits an injected op probe after the advance, and waits for the next
scheduled sleep before asserting the named turn in history. Advancing before
the first acknowledgement would race task startup; merely checking state that
the seeding closure already established would not prove the task ran.

There is no late-start API, even for tests: the factory mirrors production's
single-call bootstrap exactly, and arrangement slots into the only point
where it can matter. Testing one mechanism means passing only that mechanism
with fake dependencies. `CogTesting` publishes `seed` only behind
`#if DEBUG`; an app importing only `Cog` has no such operation. Seeding that
precedes `operate` is what `initial: .run` reactions observe; seeding after
bootstrap remains safe, because a seed marks its dependents dirty and the
next real turn settles them before reactions run.[^seed]

### 6.7 Background work that outlives the process

Background downloads and sync break a basic assumption: the app may die while
work continues, so in-memory graph state cannot be the source of truth. Three
rules follow:

1. **The graph is a view of durable data.** Store subscriptions, episode
   records, and download status in SQLite, GRDB, or another durable store. An
   op writes the store first, then its manual cog; a crash between those
   writes loses only the in-memory update. A GRDB `ValueObservation` may
   instead feed the graph as an external input (§8).
2. **A headless app runtime uses its one normal `Cogs`.** App bootstrap
   creates and configures it once, mechanisms and all, even when no scene
   appears. UI-only work stays safe because it lives in views. A background
   task owns its deadline; expiration cancels its op, while a cancellation
   shield can protect the final turn (`withTaskCancellationShield` in Swift
   6.4).
3. **System-owned work is not an `AsyncCog`.** An async cog models a task
   owned by the current process. A background `URLSession` transfer can
   outlive that task. Model its status as manual state such as `.queued`,
   `.downloading`, `.downloaded`, or `.failed`, and let an engine own the
   transfer.

The graph connects to the engine through a **reconciler**: a mechanism
reaction that compares desired state with the engine's actual state:

```swift
let episodesToDownloadCog = Cog { c in
    let subscribedEpisodes = c[subscribedEpisodesCog]
    let autoDownloadPolicy = c[autoDownloadPolicyCog]
    return subscribedEpisodes
        .filter { episode in
            let downloadState = c[downloadStateCogs[episode.id]]
            return autoDownloadPolicy.wants(episode)
                && !downloadState.isDownloadedOrInFlight
        }
        .map(\.id)
}

final class DownloadsMechanism: Mechanism {
    let makeEngine: (
        @escaping @Sendable (EpisodeID, URL) -> Void
    ) -> DownloadEngine
    private var engine: DownloadEngine?

    init(
        makeEngine: @escaping (
            @escaping @Sendable (EpisodeID, URL) -> Void
        ) -> DownloadEngine
    ) {
        self.makeEngine = makeEngine
    }

    func operate(_ m: MechanismController) {
        let engine = makeEngine { [weak m] id, file in
            Task { @MainActor [weak m] in
                guard let m else { return }
                await m.finishDownload(of: id, at: file)
            }
        }
        self.engine = engine

        m.watch(episodesToDownloadCog, initial: .run,
                name: "reconcile") { _, wanted in
            engine.reconcile(desired: wanted)
        }
    }
}
```

The class mechanism constructs and retains the engine during `operate`, giving
it an immutable callback before delegate activity begins. That callback weakly
captures the mechanism controller rather than raw `Cogs` and hops from the
delegate queue to the MainActor before calling an op. If the runtime has ended
before a replayed callback arrives, controller promotion fails and the callback
does nothing. The engine always stores durable data before asking the op to
publish graph state.[^engine]

A refresh entry point stays small:

```swift
.backgroundTask(.appRefresh("app.feedRefresh")) {
    await cogs.refreshAllFeeds()
    await cogs.scheduleNextRefresh()
}
```

The full flow:

1. The system launches the app without a scene. The app bootstraps the graph
   from the store with its mechanisms.
2. Feed refresh turns new episode rows.
3. The automatic desired-set cog changes. The reconciler hands IDs to the background
   session, then the short refresh task returns without downloading files.
4. The app may stop. `nsurlsessiond` keeps transferring.
5. Completion launches the app again. The engine reconnects to its session
   identifier, receives replayed delegate events, and calls ops that update
   the store and graph.
6. An ordinary reaction can now post a “new episodes” notification.

Feed refresh, policy changes, storage cleanup, and user taps only change
state. One reconciler owns the imperative `URLSession` edge.

## Appendix A: iOS background tools

- `BGAppRefreshTask` gives short, system-scheduled wakes, often around 30
  seconds. SwiftUI exposes it through `.backgroundTask(.appRefresh(id))` on
  iOS 16 and later.
- `BGProcessingTask` allows minutes of work and can require power or network.
- `BGContinuedProcessingTask` on iOS 26 continues user-started foreground work
  with system-visible progress. It fits an explicit “Download now” action.
- Background `URLSession` runs transfers in `nsurlsessiond`, outside the app
  process. Transfers survive suspension and death, and completion can launch
  the app through `handleEventsForBackgroundURLSession`. It uses delegate
  APIs, not the async conveniences. `isDiscretionary` lets the system schedule
  bulk work around power and network conditions.
- A silent push with `content-available` can suggest a server-triggered
  refresh, but the system may delay or drop it. It is not a schedule.

See Apple's [BackgroundTasks](https://developer.apple.com/documentation/backgroundtasks)
and [background download](https://developer.apple.com/documentation/foundation/url_loading_system/downloading_files_in_the_background)
guides.

## Appendix B: background engine sketch

```swift
final class DownloadEngine: NSObject, URLSessionDownloadDelegate {
    // URLSessionConfiguration.background(withIdentifier: "app.downloads")
    // Use isDiscretionary for policy-driven automatic downloads.

    private let onDownloadFinished: @Sendable (EpisodeID, URL) -> Void

    init(
        onDownloadFinished: @escaping @Sendable (EpisodeID, URL) -> Void
    ) {
        self.onDownloadFinished = onDownloadFinished
        super.init()
    }

    func urlSession(_ session: URLSession,
                    downloadTask task: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let id = episodeID(for: task)
        let file = try! library.claim(location, for: id)
        onDownloadFinished(id, file)
    }
}
```

The file must move before the delegate returns. Callbacks arrive on a
background queue; the mechanism-installed callback owns the MainActor hop and
weak controller promotion. Coalesce frequent progress events before that hop —
for example, write only when the whole-number percent changes. Equality checks
remove duplicate values, but cannot remove the cost of too many turns.

[^seed]:
    `seed` stages its value and pushes dirty flags exactly like a real write,
    so dependent states and reaction roots recheck it on the next read or turn.
    It skips the rest of the flush: no turn record, `withMutation` notice, or
    reaction run. The dirty push is required, not an optimization. Without it,
    a reaction registered before the seed would keep the dependency set from
    its registration run and never rerun: in the test above, the alert
    reaction initially depends only on `currentZipCog` (no ZIP means the
    selector returns early), so a later weather turn would find no subscriber
    edge to follow and the alert would never fire.

[^engine]:
    A process-owned `AsyncCog` can cancel and restart Swift tasks. A
    system-owned transfer has no live Swift task after process death, so its
    engine and durable status must carry the lifecycle instead.
