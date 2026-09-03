---
description: "Build a small SwiftUI screen on Cog: declare state, assemble one runtime, read and change values from a view, and test the state layer."
---

# Getting started

This tutorial builds a small SwiftUI screen backed by Cog. It starts at 60°,
computes clothing advice from that temperature, and updates both values when
you press a button.

By the end, you will know how to:

- declare writable and automatically computed state;
- assemble Cog once and install it in the SwiftUI environment;
- read state from a view and change it through a named operation; and
- test the same state without launching the UI.

Start with a SwiftUI app that has `Cog` in its app target and `CogTesting` in
its test target. [Install Cog](./installation.md) first if those products are
not available yet.

All graph access in this tutorial runs on the MainActor.

## Declare state and an operation

Create a state-layer file. Keep the writable source and the operation that
changes it together so Swift's `private` access control protects the write
boundary.

```swift [ForecastRig+Cogs.swift]
import Cog

@MainActor
private let _temperatureCog = Cog<Int>.Manual { 60 }

@MainActor
let temperatureCog = _temperatureCog.readOnly

@MainActor
let adviceCog = Cog<String> { c in
  c[_temperatureCog] >= 70 ? "shorts" : "coat"
}

extension CogOps {
  func warmUp() {
    turn { c in c[_temperatureCog] += 10 }
  }
}
```

`_temperatureCog` is the one writable source. Its `readOnly` projection gives
the rest of the app a value it can read but cannot write. `adviceCog` is
automatic: Cog computes it on its first read, caches the result, and computes
it again only after a value it read has changed.

Application code does not call `turn` directly. It calls the domain operation
`warmUp()`, which publishes all writes in its turn atomically. Defining the
operation on `CogOps` makes the same verb available to the app runtime and to
mechanism controllers.

## Assemble Cog once

Replace the app entry point with one that creates the runtime and installs it
above the view hierarchy.

```swift [ForecastApp.swift]
import Cog
import SwiftUI

@main
@MainActor
struct ForecastApp: App {
  private let cogs: Cogs

  init() {
    cogs = Cogs.assemble()
  }

  var body: some Scene {
    WindowGroup {
      Dashboard()
        .cogEnvironment(cogs)
    }
  }
}
```

::: warning One graph per app
`Cogs.assemble()` is a launch-time operation. A second call traps in debug and
release builds because it would give the app two conflicting state graphs.
Tests and previews use isolated runtimes instead.
:::

## Put the values on screen

Create the dashboard. Every view that uses Cog resolves the runtime from the
environment itself.

```swift [Dashboard.swift]
import Cog
import SwiftUI

struct Dashboard: View {
  @Environment(\.cogs) private var cogs

  var body: some View {
    let temperature = cogs[temperatureCog]
    let advice = cogs[adviceCog]

    VStack(spacing: 12) {
      Text("\(temperature)°")
      Text("Wear \(advice).")
      Button("Warmer") { cogs.warmUp() }
    }
    .padding()
  }
}
```

Run the app. It initially shows **60°** and **Wear coat.** Press **Warmer**
once; it changes to **70°** and **Wear shorts.**

Each subscript in `body` is a tracked read. When `warmUp()` publishes the new
temperature, Cog invalidates only views that read the changed temperature or
the advice computed from it. Outside a view body, use `cogs.peek(...)` for a
settled one-time read that creates no UI subscription.

## Test the state layer

A test uses the declarations and operations the app ships, but gives them a
fresh isolated runtime. Replace `Forecast` below if your app module has a
different name.

```swift [ForecastStateTests.swift]
@testable import Forecast
import CogTesting
import Testing

@MainActor
@Test("Warming through the threshold changes the advice")
func warmingChangesAdvice() {
  let cogs = Cogs.forTesting()

  #expect(cogs.peek(adviceCog) == "coat")
  cogs.warmUp()
  #expect(cogs.peek(adviceCog) == "shorts")
}
```

Run the test with Xcode's **Product ▸ Test** command (`⌘U`). If the app module
is part of your own Swift package, `swift test` runs its package tests.

`Cogs.forTesting()` neither occupies the production assembly slot nor shares
state with another test, so there is nothing to reset or uninstall.

## Optional: react outside the UI

App-wide side effects live in mechanisms. This one watches the computed advice
and writes its next change to the console.

```swift [ForecastRig+Mechanisms.swift]
import Cog

struct AdviceMechanism: Mechanism {
  func operate(_ m: MechanismController) {
    m.watch(adviceCog, initial: .skip, name: "adviceChanged") { _, advice in
      print("Now: \(advice)")
    }
  }
}
```

Register it in `ForecastApp.init`:

```swift [ForecastApp.swift]
cogs = Cogs.assemble(mechanisms: [AdviceMechanism()])
```

Run the app and press **Warmer**. The screen updates and the console prints
`Now: shorts`. A mechanism left out of the assembly list never runs; that list
is the app's complete app-wide side-effect surface.

## What you learned

- Manual state has one private writable source and a public read-only face.
- Automatic state records its dependencies as it computes.
- Views read values directly and call named `CogOps` operations to change them.
- Production assembles one runtime; each test creates one isolated runtime.
- Mechanisms own reactions that outlive a particular view.

## Where to go next

- [Structure a larger state layer](./handbook/app-structure.md) with
  feature-sized rigs.
- [Load asynchronous data](./handbook/declaring-state.md) with async cogs and
  explicit status.
- [Add persistence or background work](./handbook/side-effects.md) with
  mechanisms and injected capabilities.
- [Test time and asynchronous work](./handbook/testing.md) without waiting on
  wall-clock time.
- [Add CogLint](https://skeswa.github.io/cog/documentation/cog/lintingyourapp)
  to enforce the conventions used here.
- Browse the [API reference](https://skeswa.github.io/cog/documentation/cog/)
  when you need a specific symbol.
