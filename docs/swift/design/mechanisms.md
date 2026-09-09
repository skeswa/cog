# Cog for Swift: mechanisms and background work

_August 14, 2026_

This file is §6 of [core design](./exploration.md). It explains where side
effects live, how they start and stop, how to test them, and how to handle work
that outlives the app process.

## 6. Side effects, worked

A side effect changes something outside the graph, such as an alert, haptic,
log, file, or system service. A **mechanism** groups that work with the services,
clocks, reactions, and tasks it needs. All app-wide reactions and tasks live in
named mechanisms registered at assembly.

### 6.1 Choosing a home for a side effect

| Need                                  | Use                                                         |
| ------------------------------------- | ----------------------------------------------------------- |
| Compute state from other state        | `Cog<Value>.Async` (§5.1), or an op that writes manual cogs |
| Send something outside the graph      | A reaction inside a mechanism                               |
| Respond to a user action              | Op (§3.2)                                                   |
| Run for the app lifetime              | A mechanism registered at assembly                          |
| Run for a shorter domain lifetime     | A `scope` inside a mechanism (§6.2)                         |
| Live only while one screen is visible | SwiftUI `.task` and a `values` stream (§6.5)                |
| Continue after process death          | Durable state, an engine, and a reconciler (§6.7)           |

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
    /// Called exactly once, during assembly, in array order.
    func operate(_ m: MechanismController)
}
```

Both structs and classes may conform. Use stored properties for dependencies.
A class fits a mechanism that owns a connection or other shared resource. The
runtime retains each mechanism. At teardown it cancels the mechanism's scope
before releasing the value, so owned resources stay alive while work can use
them.

```swift
// WeatherRig+Mechanisms.swift

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

The controller `m` is the mechanism's only link to the graph:

- `m.watch` registers a reaction on one cog and receives its old and new
  values. `.skip` avoids an alert during assembly. `m.run` registers a
  reaction over several dependencies; it runs once during registration to
  record them (§3.3).
- `m.task` starts a Swift task owned by the mechanism's scope. Timed work uses
  an injected `Clock`. A long task captures `m` weakly and holds it only while
  touching the graph, so teardown need not wait for cancelled code to return.
- `m.peek` makes an untracked read (§2.4); an `operate`-time read never
  becomes a dependency, because `operate` is registration, not a reaction.
- Ops are available on `m` directly, because ops extend `CogOps` and
  the controller conforms (§3.2). `m.turn` and `m.refresh` are the
  primitives beneath them.
- Each registration has a name. Names compose under the mechanism name, so the
  task above appears as `Weather.hourlyRefresh` in history and Instruments.

The controller does not expose raw `Cogs`. All access goes through `m`, which
keeps names and isolated tests exact.

`MechanismController` is a final-class lifetime token owned by its scope, not by
the app runtime. Work that may outlive the scope captures `[weak m]` and stops
when that value is gone. An external engine must not retain the controller.
The same rule applies to a `scope` sub-controller.

**Scopes.** Use `.scope(...)` to run work while a selected state says it is
needed. For example, a Bool can start a timer when a screen opens and stop it
when the screen closes. An optional ID can choose one screen's work, and an
array of IDs can keep work running for several screens at once. See the
[handbook's step-by-step examples](../handbook/side-effects.md#scopes-start-and-stop-work-with-state).
The simplest form selects a Bool:

```swift
func operate(_ m: MechanismController) {
    m.scope(isLoggedInCog, name: "session") { s in
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

- The selected state is the scope's only tracked dependency. When the gate
  reads true — at registration or after a later turn — the body runs once with
  a fresh sub-controller and its registrations become live.
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
  `scope`, and names continue to compose (`Session.heartbeat` above
  becomes `Weather.session.heartbeat` when nested under `session`).

There is no public effect group or reaction token. Assembly owns app-lifetime
work. State owns shorter work.

**Scopes owned by an identity.** A Bool says whether work should exist. It
cannot say _which_ lifetime owns it, and that difference decides whether a
replacement is expressible at all. Consider a session ending and another
beginning while onboarding stays active:

```text
Before: sessionEpoch = A, onboardingActive = true
After:  sessionEpoch = B, onboardingActive = true
```

A scope gated on `onboardingActive` stays open, still holding session A's
credentials and its in-flight work. Forcing a false/true cycle is not a fix: in
one atomic turn observers only ever see the settled gate, and in separate turns
the application has invented an inactive state that never happened, purely to
operate the lifecycle machinery.

Selecting an optional identity says it directly:

```swift
m.scope(activeOnboardingCog, name: "onboarding") { lifetime, s in
    let credentials = credentialProvider.bound(to: lifetime.sessionEpoch)
    s.watch(onboardingStepCog, initial: .run, name: "sync") { _, step in
        sync.advance(step, using: credentials)
    }
}
```

The body receives the exact nonoptional identity that opened it, so the lifetime
it belongs to is a value in scope rather than something to re-read later. The
transitions:

| Observation                         | Result                                               |
| ----------------------------------- | ---------------------------------------------------- |
| Initially `nil`                     | Install the selector; open no child                  |
| Initially `A`                       | Open `A` once, under ordinary registration ordering  |
| `nil → A`                           | Open a fresh child; run the body once                |
| `A → A`, including a distinct equal | Keep the same child; no restart                      |
| `A → B`                             | Retire `A`, then open `B` at the selector's position |
| `A → nil`                           | Retire `A`; open nothing                             |
| `A → nil → A` in completed turns    | A second, different `A`; the first stays retired     |
| One turn staging `A → B → A`        | Nothing: only the settled value is a transition      |
| Parent or runtime teardown          | Retire this child and every descendant               |

Both families are one implementation. A Bool maps internally to "no identity" or
one fixed private identity, which is why callers never invent a sentinel
optional cog for an ordinary condition, and why the Bool body still receives
only its controller. The identity form requires `Equatable` and not `Hashable`:
a registration owns one active lifetime, so it needs `==` and nothing more.

Equality is checked at the scope as well as by the graph, so a source
configured to publish equal values cannot restart an unchanged lifetime. The
obligation runs both ways: the selected cog must expose lifetime changes
faithfully, because a custom `==` that calls two genuinely different lifetimes
equal hides a replacement Cog can never perform.

Identity is minted by the domain operation that creates the lifetime — signing
in, opening a screen, starting a workflow — and stored in state. Never mint one
while a selector recomputes: that makes recomputation manufacture a lifetime.
Signing the same account in again is a new epoch; refreshing a token is not.
Search text and filters normally select a _request_ inside a presentation
rather than a new presentation. And a workflow that must end when the session is
replaced puts the session epoch in its own identity, even if its navigation
entry survives.

**Scopes over a collection.** One selected identity fits a session, a current
workflow, or a fixed sheet slot. A navigation stack is a different shape:
entries arrive and leave in any order, and two entries can address the same
resource while owning separate work. Registering a selector per entry would open
and retire children correctly, but nothing would ever remove the selectors
themselves, so a long session would accumulate one dormant watch per entry ever
pushed. Rebuilding one whole stack scope on every membership change avoids that
by restarting every surviving entry, which is worse.

`scope(each:)` is the collection form of the same child lifecycle — one
selector registration in total, one child per live identity:

```swift
m.scope(each: openPresentationIDsCog, name: "presentation") { id, s in
    s.watch(searchQueryCogs[id], initial: .skip, name: "search") { _, query in
        search.run(query, for: id)
    }
}
```

Reconciliation compares membership, never position. An identity that arrives
opens a child; one that stays keeps its exact child instance, registrations,
tasks, and leases; one that leaves retires its child. Reordering alone changes
nothing. Removing an identity and adding it back in a later turn opens a second,
different child, while an identity that leaves and returns inside one atomic
turn never left. Departed children retire first, in opening order, and added
ones open in collection order. Identities must be distinct: a collection holding
the same identity twice describes two lifetimes nothing could tell apart, and it
fails in debug and release builds.

This form takes `Hashable`, unlike the single-identity form. That is an
independent constraint on an independent operation: membership reconciliation
and duplicate detection are set operations, which `==` alone cannot perform in
reasonable time.

**Retirement revokes authority.** Retiring a scope is not only a request that
its tasks stop. A weak capture is the right ownership convention, but it is not
the safety mechanism: work can promote the reference and then suspend across an
`await`, and a retained `status` lens keeps a controller alive by itself. So
retirement revokes what the controller can do:

| Operation through a retired controller | Behavior                                              |
| -------------------------------------- | ----------------------------------------------------- |
| `turn`, and every op built on it       | Inert before the writer body runs or work is enqueued |
| A turn already waiting in the FIFO     | Rejected at its execution point, publishing nothing   |
| `run`, `watch`, `status.watch`         | Inert before any baseline read, callback, or lease    |
| Either `scope` family                  | Inert before the selector is read or a body runs      |
| `task`                                 | An already-cancelled task; the operation never starts |
| `peek`, `status.peek`, `refresh`       | Trap, naming the operation and the composed scope     |

Reads trap because the signature cannot honestly manufacture a `Value`, and a
rejected `refresh` must not answer `.released`: that outcome means the owning
state left the graph, which is a claim about shared state that one ended
presentation is in no position to make. A handle obtained while the controller
was live keeps its real exact-generation outcome; retirement never rewrites it.

Retirement is marked across a whole subtree before any teardown work begins.
Without that ordering the guarantee would depend on traversal accidents: a
child's cleanup releases its captures, and a deinitializer running there is
application code that can reach a sibling the walk has not visited yet.

Two limits are part of the contract. Revocation covers operations routed through
the controller, not whole methods: a `CogOps` extension is an ordinary Swift
function, and the statements before it reaches a primitive still run. And a
synchronous frame that retires its own scope cannot be unwound — later
primitives in that frame observe retirement, but the frame continues.

**Queued writes are admitted at execution time.** A turn requested during a
flush waits in the ordinary FIFO (§6.4). Between queuing and draining, an entry
ahead of it may retire the scope that asked:

```text
During one reaction flush:
  an earlier reaction queues the session replacement turn
  a reaction in the still-live A scope queues an A write

FIFO drain:
  the replacement turn publishes B and retires A
  A's queued write now reaches its execution point
```

That write is discarded, and discarded _before_ its turn starts: no revision, no
history entry, no writer body, no empty published turn. The check is the exact
scope instance, not the selected domain identity, because identities are reused
— an app that returns to session A after B has a second, different A, and the
first one's work must stay rejected.

Nothing else about ordering changes. Admitted entries keep their arrival order,
a replacement never overtakes an earlier write, and a child write that reaches
its execution point before the replacement is valid and is never rolled back.
Replacement also never waits for cancellation-resistant work to return: the new
child opens while the old one's request is still in flight, which is the only
honest behavior when the request has already been sent.

**Late completions publish through receipts, not prechecks.** Because `turn` is
inert after retirement and its writer body is the guarded place, the ordinary
completion path needs no liveness check at all:

```swift
s.task(name: "load") { [weak s] in
    let page = try await service.load(cursor, using: credentials)
    await MainActor.run { s?.acceptPage(page, receipt: lifetime) }
}

extension CogOps {
    func acceptPage(_ page: Page, receipt: PresentationID) {
        turn { c in
            guard c[_currentPresentationCog] == receipt else { return }
            c[_pagesCogs[receipt]] = page
        }
    }
}
```

The receipt validation and the acceptance reads are inside the writer body, so a
retired scope never reaches them, and a live one still has to prove its work is
current. Domain receipts remain necessary either way: scope retirement is about
registrations, and acceptance is about results.

When a completion genuinely has to _read_ — to decide whether to retry, or to
ask for follow-up demand — `ifLive` is the recoverable spelling:

```swift
guard let s, s.ifLive({ $0.peek(isPresentedCog) }) == true else { return }
```

It checks once, at entry. It is not a lease on the rest of the closure: a turn
inside its body can retire that very scope, and the primitives after it are
authoritative. Re-check after every suspension, because a check made before an
`await` says nothing about the world after it.

**What replacement does not fix.** A scope keeps every task it started until it
retires, completed ones included. Replacement clears that ownership along with
everything else, so a session that is replaced releases its handles — but a
session that runs for hours and starts a task per keystroke accumulates handles
the whole time, and identity scopes change nothing about it. Do not read
`s.task` per keystroke as the recommended search shape; work whose purpose is
producing graph state belongs in an async cog (§5.1), whose generation rules
already own exactly one run. If lifetime-local handle accumulation needs fixing,
it is its own change with its own justification.

**Scope ownership is not state ownership.** Retiring a scope ends its
registrations and requests cancellation of its tasks. It issues no writes,
resets no sources, and is not a feature-reset registry. What a departed lifetime
left in the graph is governed by that state's own declared retention (§5.3), and
shared resource state stays owned by its other consumers: removing one
presentation must not destroy state another is using. Releasing a reaction's
lease can legitimately start ordinary grace, so "no implicit reset" does not
mean "retirement never affects retention" — it means retirement never decides
retention.

### 6.3 Assembly-only registration and lifecycle

Mechanisms are specified when the app runtime is assembled, and nowhere
else:

```swift
@main
struct WeatherApp: App {
    @State private var cogs: Cogs

    init() {
        let cogs = Cogs.assemble(mechanisms: [
            WeatherMechanism(notifier: .live),
        ])
        _cogs = State(initialValue: cogs)
    }

    var body: some Scene {
        WindowGroup { RootView().cogEnvironment(cogs) }
    }
}
```

`assemble(mechanisms:)` builds the runtime, calls each `operate` in array
order, and then returns:

- **Every mechanism is live when assembly returns.** Registration is not lazy,
  and no API can add a mechanism later.
- **Order is exact.** Reactions keep registration order. A write during
  `operate` is a normal named turn that settles before the next mechanism runs.
- **Names are unique.** A duplicate mechanism name fails in debug and release
  builds.
- **Reactions have one entry point.** Only a controller can register `run`,
  `watch`, or tasks. Handles stay internal, and scope cancellation is final and
  safe to repeat.

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

Mechanisms can still form a turn → reaction → turn loop. After about 64 turns
without reaching idle, a debug guard warns and prints the named cause chain.
Tests capture this through an internal diagnostic hook and use a finite chain
that stops after crossing the limit.

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

If work matters only while one screen is visible, let SwiftUI own it. Put
app-wide notifications and analytics in a mechanism, with `scope` when they
need a shorter state-driven lifetime. One effect should not use both owners.

### 6.6 Testing mechanisms

Writable sources are `private` or `fileprivate`, so even `@testable import`
cannot reach them. The owning state file exposes only narrow, debug-only seed capabilities
and any loud domain helpers:

```swift
// WeatherRig+Cogs.swift
#if DEBUG
let currentZipSeedTargetCog = _currentZipCog
let weatherSeedTargetsCogs = _weatherReportCogs

extension CogOps {
    func stubWeather(_ report: Weather?, zip: ZipCode) {
        turn { c in c[_weatherReportCogs[zip]] = report }
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

Tests have no late-start API. Pass only the mechanism under test and give it
fake dependencies. `CogTesting` exposes `seed` only in debug builds. Seeds
before `operate` are visible to `initial: .run`; a later seed marks dependents
dirty so the next real turn settles them before reactions run.[^seed]

### 6.7 Background work that outlives the process

Background downloads and sync break a basic assumption: the app may die while
work continues, so in-memory graph state cannot be the source of truth. Three
rules follow:

1. **The graph is a view of durable data.** Store subscriptions, episode
   records, and download status in SQLite, GRDB, or another durable store. An
   op writes the store first, then its manual cog; a crash between those
   writes loses only the in-memory update. A GRDB `ValueObservation` may
   instead feed the graph as an external input (§8).
2. **A headless app runtime uses its one normal `Cogs`.** App assembly
   creates and configures it once, mechanisms and all, even when no scene
   appears. UI-only work stays safe because it lives in views. A background
   task owns its deadline; expiration cancels its op, while a cancellation
   shield can protect the final turn (`withTaskCancellationShield` in Swift
   6.4).
3. **System-owned work is not a `Cog<Value>.Async`.** An async cog models a task
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

The class mechanism creates and retains the engine during `operate`. Its fixed
callback holds the controller weakly, moves from the delegate queue to the
MainActor, and then calls an op. A callback after teardown does nothing. The
engine stores durable data before it publishes graph state.[^engine]

A refresh entry point stays small:

```swift
.backgroundTask(.appRefresh("app.feedRefresh")) {
    await cogs.refreshAllFeeds()
    await cogs.scheduleNextRefresh()
}
```

The full flow:

1. The system launches the app without a scene. The app assemblys the graph
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
    A process-owned `Cog<Value>.Async` can cancel and restart Swift tasks. A
    system-owned transfer has no live Swift task after process death, so its
    engine and durable status must carry the lifecycle instead.
