# Getting started

Add Cog to an app, declare some state, and put it on screen.

## Overview

This article builds the smallest complete thing: one source of state, one value
computed automatically from it, a view that reads both, and a button that writes. Everything
here is MainActor code — Cog's graph is MainActor-confined, so there is no
queue to choose and no lock to hold.

### Add the package

Cog resolves with no dependencies of its own. Pin it to a minor version; 0.x
minors may break, and patches never do.

```swift
// x-release-please-start-version
dependencies: [
  .package(
    url: "https://github.com/skeswa/cog.git",
    .upToNextMinor(from: "0.4.0")
  )
]
// x-release-please-end
```

Add `Cog` to your app target, and `CogTesting` to your test and
preview-support targets. Cog requires iOS 17 or macOS 14 and Swift 6.2.

### Bootstrap once, at launch

An app has exactly one graph. Create it at launch with
``Cogs/bootstrapApp(mechanisms:)``, retain what it returns, and install it
above every scene. There is no ambient lookup and no second chance: bootstrap
twice and Cog traps, in debug and release alike, because a second graph would
mean two answers to the same question.

```swift
import Cog
import SwiftUI

@main
@MainActor
struct ForecastApp: App {
  private let cogs: Cogs

  init() {
    cogs = Cogs.bootstrapApp(mechanisms: [])
  }

  var body: some Scene {
    WindowGroup {
      Dashboard()
        .cogEnvironment(cogs)
    }
  }
}
```

The `mechanisms:` array is where side effects go; "Run a side effect" below
comes back to it.

### Declare state

Sources are the facts your app is told. Everything else is computed automatically from them.

```swift
private let temperatureSourceCog = Cog<Int>.Manual(60, name: "temperature")

let temperatureCog = temperatureSourceCog.readOnly

let adviceCog = Cog<String>(
  { c in c[temperatureSourceCog] > 70 ? "shorts" : "coat" },
  name: "advice"
)
```

Three things are worth noticing:

- Declarations are ordinary `let`s, usually at file scope. They allocate a
  name, not state; no graph exists yet, and `adviceCog`'s closure has not run.
- `temperatureSourceCog` is `private`, and ``Cog/Manual/readOnly`` publishes a
  version of it that cannot be written. That is how Cog controls who may write
  a fact: with Swift's own access control, not a runtime check.
- `name:` is optional. Give one and diagnostics and debug history use it;
  leave it out and they fall back to the file and line you declared it on.

Automatic values are lazy and cached. `adviceCog` runs when something first reads
it, and reruns only when a value it actually read has changed.

### Read state in a view

Every view that touches Cog resolves the runtime itself. Views never accept or
forward a ``Cogs`` through an initializer — they pass domain values to each
other, and reach for the graph individually.

```swift
struct Dashboard: View {
  @Environment(\.cogs) private var cogs

  var body: some View {
    let temperature = cogs[temperatureCog]
    let advice = cogs[adviceCog]

    VStack {
      Text("\(temperature)°")
      Text("Wear \(advice).")
      Button("Warmer") { cogs.warmUp() }
    }
  }
}
```

`cogs[...]` is a tracked read: it registers this exact state with SwiftUI's
Observation, so a later change to it redraws this view and nothing else. Bind
the result to a local named for the declaration without its `Cog` suffix — the
value is what the rest of the body should be talking about.

Outside a `body`, in a button action or any escaping closure, use the one-shot
``Cogs/peek(_:)-(Cog<Value>)`` instead. It returns a fully settled value
without leaving a subscription behind.

### Write state

Writes happen in turns. One `turn` is one turn, however many values it
touches, and everything it wrote becomes visible at the same moment.

```swift
extension Cogs {
  func warmUp() {
    turn { c in c[temperatureSourceCog] += 10 }
  }
}
```

Two details make this the shape to copy:

- The op is a method on ``Cogs`` (or on ``CogOps``, which a mechanism's
  controller also conforms to), so views call `cogs.warmUp()` and never write
  state inline.
- `c` here is a ``Writer``. Reading through it sees this turn's staged values,
  which is what makes `+= 10` mean what it looks like.

For a single value there is a compact form, ``Cogs/turn(_:to:name:)``:

```swift
cogs.turn(temperatureSourceCog, to: 72)
```

Both spellings name the turn after the calling function by default, which is
what debug history shows you later.

The same rule covers ``Cogs/refresh(_:)``. `turn` and `refresh` are how the
graph is *asked* to do something; they are not what your app calls the asking.
Wrap them in domain verbs and let views say what they want:

```swift
extension CogOps {
  func refreshForecast(for zip: ZipCode) {
    refresh(forecastCogs[zip])
  }
}
```

When a view needs several values, read each one flatly:

```swift
var body: some View {
  let forecast = cogs.status[forecastCogs[zip]]
  let temperature = cogs[temperatureCogs[zip]]
  let advice = cogs[adviceCogs[zip]]
  ...
}
```

Resist gathering them into a projection struct. Reads in one `body` already
come from one settled turn, so they cannot tear, and each registers on its own,
so an unrelated turn invalidates nothing — a wrapper adds a layer you have to
read to know what the view depends on, and invites being stored or passed
onward. If a value is genuinely *automatic* rather than merely read alongside
others, declare an automatic cog for it and read that flatly too.

### Run a side effect

Anything that reacts to state — a network request, a timer, a notification —
is a ``Mechanism``, and every mechanism is registered at bootstrap. There is no
later installation point, so an app's whole side-effect surface is the array
you can read at launch.

```swift
struct AdviceMechanism: Mechanism {
  func operate(_ m: MechanismController) {
    m.watch(adviceCog, initial: .skip, name: "adviceChanged") { _, advice in
      print("Now: \(advice)")
    }
  }
}
```

Register it in the array from earlier:

```swift
cogs = Cogs.bootstrapApp(mechanisms: [AdviceMechanism()])
```

The controller — never a raw ``Cogs`` — hands a mechanism what it may do:
``MechanismController/run(fileID:line:_:)`` for a tracked reaction, `watch` for
old-and-new value delivery, `task` for long-running work, and `whenever` for a
scope that lives only while some state is true. Writes from a mechanism queue a
new turn rather than reentering the current one.

### Test it

Tests and previews are separate runtimes, each with its own isolated graph.
`CogTesting` vends one; it never occupies the production slot and needs no
cleanup.

```swift
import Cog
import CogTesting
import Testing

@MainActor
@Test func advice() {
  let cogs = Cogs.forTesting()

  #expect(cogs.peek(adviceCog) == "coat")
  cogs.turn(temperatureSourceCog, to: 80)
  #expect(cogs.peek(adviceCog) == "shorts")
}
```

The same declarations you shipped are the ones under test — no fixtures, no
reset, no shared state between tests.

## See Also

- ``Cogs``
- ``Mechanism``
