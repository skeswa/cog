# Cog for Swift: effects and background work

_August 9, 2026_

This file is §6 of [exploration.md](./exploration.md). It covers effects,
their lifetimes, testing, and work that can outlive the app process. Other
section numbers point to the core file.

## 6. Side effects, worked

An effect changes something outside the graph: alerts, haptics, logs, files,
system services. Work that only computes graph state is not an effect. Keeping
that boundary clear makes application behavior easier to read.

### 6.1 Choosing a home for an effect

| Need                                  | Use                                                 |
| ------------------------------------- | --------------------------------------------------- |
| Compute state from other state        | `AsyncCog` (§5.1), or an op that writes manual cogs |
| Send something outside the graph      | Reaction                                            |
| Respond to a user action              | Op (§3.2)                                           |
| Run for the app lifetime              | Reaction or task owned by `cogs.effects`            |
| Run for a shorter domain lifetime     | Task owned by that domain's `EffectGroup`           |
| Live only while one screen is visible | SwiftUI `.task` and a `values` stream (§6.5)        |
| Continue after process death          | Durable state, an engine, and a reconciler (§6.7)   |

For example, “check the weather when the ZIP changes” produces state, so it
belongs in the `fetchedWeatherCogs` async box from §5.1. “Alert me when the
weather becomes nice” leaves the graph, so it is a reaction.

### 6.2 App-lifetime and scoped effect groups

```swift
// WeatherEffects.swift

struct WeatherEffects {
    var notifier: Notifier
    var clock: any Clock<Duration> = ContinuousClock()

    func install(in cogs: Cogs) {
        cogs.effects.add(cogs.watch(isNiceOutsideHereCog, initial: .skip,
                                    name: "weather.niceAlert") { was, nice in
            if nice && !was {
                notifier.alert("It is nice outside!")
            }
        })

        cogs.effects.task(name: "location.hourlyRefresh") { [weak cogs] in
            while true {
                try await clock.sleep(for: .seconds(3_600))
                guard let cogs else { return }
                await cogs.refreshCurrentLocation()
            }
        }
    }
}
```

The pieces have narrow jobs:

- `watch` handles one cog and receives its old and new values. `.skip` avoids
  an alert during installation. Use `run` for several dependencies; it runs
  once during registration to record them.
- Time-based effects are normal structured tasks. An injected `Clock` makes
  them testable. Their bodies call ops, so writes keep useful names in debug
  history.
- `Cogs.effects` is the `EffectGroup` already owned by the app runtime. A
  shorter-lived screen or domain creates and owns a separate group. A
  long-running root task captures `cogs` weakly so isolated test and preview
  runtimes can still deinitialize; each iteration promotes it only while
  performing graph work.
- `EffectGroup.cancel()` and deinit both cancel the group; copies point to the
  same terminal cancellation resource.[^group]
- Effect names appear in debug history and task names for Instruments.

The ownership rule: **`Cogs` owns app state and app-lifetime effects; a scoped
`EffectGroup` owns effects that end sooner.** `watch` and `run` still register
with the graph, while the retained token controls their lifetime. Tasks remain
on `EffectGroup`; `cogs.effects` simply supplies the root group without a
second app-level property.

### 6.3 Registration and lifecycle

Effects exist only after code calls `install`. There is no global registry or
automatic discovery, which avoids Swift's lazy top-level `let` trap: an unused
global reaction would never be created.

Group cancellation is terminal. If lifecycle ordering adds a live reaction
token after the group has already been cancelled, `add` synchronously cancels
that token before returning, retains nothing, and never reopens the group.
Adding an already-cancelled token to that cancelled group is harmless. A task
requested after cancellation is already cancelled when `task` returns. Every
copy observes the same terminal state.

```swift
@main
struct WeatherApp: App {
    @State private var cogs: Cogs

    init() {
        let cogs = Cogs.bootstrapApp()
        _cogs = State(initialValue: cogs)
        WeatherEffects(notifier: .live).install(in: cogs)
    }

    var body: some Scene {
        WindowGroup { RootView().cogEnvironment(cogs) }
    }
}
```

The `App` creates this runtime once and shares it across every scene. Its root
effects need no parallel `@State`. A screen may own an `EffectGroup` in
`@State`, but it borrows the app runtime and never creates child `Cogs`.
Closing the screen group stops its effects without fragmenting or erasing
state.

### 6.4 Writing back into the graph

Reactions may cause writes, but never into the turn they are flushing:

1. The outer `commit` settles state.
2. Reactions run synchronously, in registration order, against that settled
   state.
3. A reaction receives only a read controller. To write, it calls an op or
   another API that opens `commit`.
4. That commit waits in a FIFO queue and becomes a new turn after the current
   flush. Nested commits during the earlier accumulating phase still join the
   current turn (§3.2).

An old captured writer also fails its turn-ID check, and async writes
naturally start later turns because they happen after an `await`.

Effects can still form a loop: turn → reaction → turn. A debug guard should
warn after about 64 turns without reaching idle and print the causal chain.
The queue prevents re-entrant graph writes; the trace makes a runaway loop
clear. An internal diagnostic seam lets tests capture the warning without
scraping logs. The guard test uses a finite reaction chain that crosses the
threshold and then stops, so warning-only behavior remains testable without an
infinite drain.

Synchronous reaction flush is deliberate: tests can assert effects on the line
after an op returns, and a short background task knows its reconciler finished
before its deadline. A future `.deferred` mode may offer next-tick coalescing,
but only as an opt-in.

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

The test: if cancellation on screen exit is correct, use SwiftUI lifecycle.
App-wide work such as notifications and analytics belongs in an installed
group. One effect should not use both.

### 6.6 Testing effects

Writable sources are `fileprivate`, so even `@testable import` cannot reach
them. The owning state file exposes only narrow, debug-only seed capabilities
and any loud domain helpers:

```swift
// WeatherState.swift
#if DEBUG
let currentZipSeedTargetCog = currentZipSourceCog
let weatherSeedTargetsCogs = weatherReportSourceCogs

extension Cogs {
    func stubWeather(_ report: Weather?, zip: ZipCode) {
        commit { c in c[weatherReportSourceCogs[zip]] = report }
    }
}
#endif

// WeatherTestSupport.swift
import CogTesting

extension Cogs {
    func seedCurrentZip(_ zip: ZipCode?) {
        seed(currentZipSeedTarget, to: zip)
    }

    func seedWeather(_ report: Weather?, zip: ZipCode) {
        seed(weatherSeedTargets[zip], to: report)
    }
}
```

`seed` comes from `CogTesting` and is quiet: no turn, history record, UI
notice, or reaction. `commit` is loud and runs a real named turn. The feature
chooses its exact test surface instead of exposing all source value references
or linking test setup into the app target.

```swift
@Test func alertsWhenTheWeatherTurnsNice() async {
    let cogs = Cogs.forTesting()
    let notifier = Notifier.recording()
    let clock = TestClock()
    WeatherEffects(notifier: notifier, clock: clock).install(in: cogs)

    cogs.seedCurrentZip(zip)
    cogs.seedWeather(.cloudy(60), zip: zip)
    #expect(notifier.alerts.isEmpty)

    cogs.stubWeather(.clear(75), zip: zip)
    #expect(notifier.alerts == ["It is nice outside!"])

    clock.advance(by: .seconds(3_600))
    let currentZip = cogs.peek(currentZipCog)
    #expect(currentZip != nil)
    clock.finish()
}
```

`CogTesting` publishes `seed` only behind `#if DEBUG`; an app importing only
`Cog` has no such operation. Seeding after effects install is safe: a seed
marks its dependents dirty, and the next real turn settles them before
reactions run.[^seed]

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
   installs and configures it once, then installs app effects even when no scene
   appears. UI-only work stays safe because it lives in views. A background
   task owns its deadline; expiration cancels its op, while a cancellation
   shield can protect the final commit (`withTaskCancellationShield` in Swift
   6.4).
3. **System-owned work is not an `AsyncCog`.** An async cog models a task
   owned by the current process. A background `URLSession` transfer can
   outlive that task. Model its status as manual state such as `.queued`,
   `.downloading`, `.downloaded`, or `.failed`, and let an engine own the
   transfer.

The graph connects to the engine through a **reconciler** that compares
desired state with the engine's actual state:

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

group.add(cogs.watch(episodesToDownloadCog, initial: .run,
                     name: "downloads.reconcile") { _, wanted in
    engine.reconcile(desired: wanted)
})
```

The engine owns the background session. Its delegate writes results through
MainActor ops, always storing durable data before graph state.[^engine]

A refresh entry point stays small:

```swift
.backgroundTask(.appRefresh("app.feedRefresh")) {
    await cogs.refreshAllFeeds()
    await cogs.scheduleNextRefresh()
}
```

The full flow:

1. The system launches the app without a scene. The app rebuilds the graph
   from the store and installs effects.
2. Feed refresh commits new episode rows.
3. The derived desired set changes. The reconciler hands IDs to the background
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

    func urlSession(_ session: URLSession,
                    downloadTask task: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let id = episodeID(for: task)
        let file = try! library.claim(location, for: id)
        Task { @MainActor in
            await cogs.finishDownload(of: id, at: file)
        }
    }
}
```

The file must move before the delegate returns. Callbacks arrive on a
background queue, so they hop to a MainActor op. Coalesce frequent progress
events before that hop — for example, write only when the whole-number percent
changes. Equality checks remove duplicate values, but cannot remove the cost
of too many turns.

[^group]:
    `EffectGroup` and reaction tokens are idempotent final classes. Explicit
    MainActor `cancel()` gives tests and lifecycle code a fixed stopping
    point. Deinit cleanup must also be safe and hop to the MainActor when
    graph removal needs it.

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
