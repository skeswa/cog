# Getting started

Build a small SwiftUI screen backed by Cog, change it through a named
operation, and test the same state with an isolated runtime.

## Overview

The finished screen starts at 60°, computes clothing advice from that
temperature, and updates both values when you press a button. All graph access
in this article runs on the MainActor.

### Add the package

In Xcode, choose **File ▸ Add Package Dependencies**, enter
`https://github.com/skeswa/cog.git`, and choose **Up to Next Minor Version**.
Add `Cog` to the app target and `CogTesting` to the test target.

For a package-based target, add Cog to the existing manifest:

<!-- x-release-please-start-version -->

```swift
dependencies: [
  .package(
    url: "https://github.com/skeswa/cog.git",
    .upToNextMinor(from: "0.6.1")
  )
],
targets: [
  .target(
    name: "Forecast",
    dependencies: [.product(name: "Cog", package: "cog")]
  ),
  .testTarget(
    name: "ForecastTests",
    dependencies: [
      "Forecast",
      .product(name: "CogTesting", package: "cog"),
    ]
  ),
]
```

<!-- x-release-please-end -->

Cog requires iOS 17 or macOS 14 and Swift tools 6.2. The
[installation guide](https://skeswa.github.io/cog/swift/installation) covers a
complete manifest and the optional binary-size trait.

### Declare state and an operation

Create `ForecastRig+Cogs.swift`. The writable source and its operation stay
together so Swift's `private` access control protects the write boundary.

```swift
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

`_temperatureCog` is the one writable source. Its
``Cog/Manual/readOnly`` projection gives the rest of the app a value it can
read but cannot write. `adviceCog` is automatic: Cog computes it on its first
read, caches the result, and computes it again only after a value it read has
changed.

Application code calls the domain operation `warmUp()` instead of calling
`turn` directly. The ``CogOps`` extension makes that operation available to
both ``Cogs`` and ``MechanismController``.

### Assemble once, at launch

Create the app's one runtime and install it above the view hierarchy:

```swift
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

``Cogs/assemble(mechanisms:)`` is a launch-time operation. A second call traps
in debug and release builds because it would give the app two conflicting
state graphs. Tests and previews use isolated runtimes instead.

### Put the values on screen

Every view that uses Cog resolves the runtime from the environment itself:

```swift
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

Each subscript in `body` is a tracked read. Cog invalidates only views that
read the changed temperature or the advice computed from it. Outside a view
body, use `cogs.peek(...)` for a settled one-time read that creates no UI
subscription.

### Test the state layer

A test uses the declarations and operation the app ships with a fresh isolated
runtime. Replace `Forecast` if the app module has a different name.

```swift
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

Run the test with Xcode's **Product ▸ Test** command. An isolated runtime never
occupies the production assembly slot or shares state with another test, so
there is nothing to reset or uninstall.

### React outside the UI

App-wide side effects live in a ``Mechanism``. This one watches the computed
advice and writes its next change to the console:

```swift
import Cog

struct AdviceMechanism: Mechanism {
  func operate(_ m: MechanismController) {
    m.watch(adviceCog, initial: .skip, name: "adviceChanged") { _, advice in
      print("Now: \(advice)")
    }
  }
}
```

Register it at assembly with
`Cogs.assemble(mechanisms: [AdviceMechanism()])`. Pressing **Warmer** then
updates the screen and prints `Now: shorts`. A mechanism left out of the list
never runs.

## See Also

- ``Cogs``
- ``CogOps``
- ``Mechanism``
- <doc:OneGraph>
