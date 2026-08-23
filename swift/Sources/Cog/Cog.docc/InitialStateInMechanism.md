# initial-state-in-mechanism

An app initializer uses a local returned directly by `Cogs.assemble` for graph work instead of only retaining it.

## Why this rule exists

An assembly mechanism's `operate` runs inside assembly, so its writes settle before `assemble` returns and before any watcher can observe the initial value on the way past. Entry-point graph work would expose an intermediate world and split production initialization from the mechanism arrangement tests can reproduce.

## How to fix it

Move initial reads, named operations, and primitive calls into a `Mechanism` supplied to `assemble(mechanisms:)`. The app initializer may construct services and mechanisms, assemble once, and retain the returned runtime directly.

<!-- Generated from the initial-state-in-mechanism CogLint fixture corpus; do not edit. -->

## Triggering examples

### Graph work around retention

A directly assembled local cannot perform named operations, reads, helpers, or primitives.

Expected diagnostic positions: 5:5, 6:9, 7:12, 9:5, 10:5.

```swift
struct WeatherApp: App {
  @State private var cogs: Cogs
  init() {
    let cogs = Cogs.assemble(mechanisms: [])
    cogs.selectCurrentLocation(.newYork)
    _ = cogs[currentZipCodeCog]
    helper(cogs)
    _cogs = State(initialValue: cogs)
    cogs.turn(currentZipSourceCog, to: .newYork)
    cogs.refresh(forecastCog)
  }
}
```

### Indirect retention value

Retention must consume the assembly result directly instead of hiding graph work in a helper.

Expected diagnostic positions: 5:41.

```swift
struct WeatherApp: App {
  @State private var cogs: Cogs
  init() {
    let graph = Cogs.assemble()
    _cogs = State(initialValue: prepare(graph))
  }
}
```

## Non-triggering examples

### Services and mechanisms before local retention

Ordinary construction may precede assembly, whose local result goes directly into `State`.

```swift
struct WeatherApp: App {
  @State private var cogs: Cogs
  init() {
    let notifier = Notifier.live
    let mechanism = WeatherMechanism(notifier: notifier)
    let cogs = Cogs.assemble(mechanisms: [mechanism])
    _cogs = SwiftUI.State<Cogs>(initialValue: cogs)
  }
}
```

### Direct assembly retention

Assigning the assembly expression directly leaves no local on which to perform work.

```swift
struct PlainApp: App {
  private let cogs: Cogs
  init() { self.cogs = Cogs.assemble(mechanisms: []) }
}
struct WrappedApp: App {
  @State private var cogs: Cogs
  init() { _cogs = State(initialValue: Cogs.assemble()) }
}
```

### Plain property retention from a local

A local may be assigned directly to the app runtime property without intervening work.

```swift
struct PlainApp: App {
  private let cogs: Cogs
  init() {
    let graph = Cogs.assemble()
    self.cogs = graph
  }
}
```

## Accepted evasions

### Factory-hidden assembly and cross-file app identity

A factory-hidden runtime and a type whose `App` conformance lives elsewhere remain syntax-only misses.

```swift
struct FactoryApp: App {
  init() {
    let cogs = makeAppGraph()
    cogs.selectCurrentLocation(.newYork)
  }
}
struct CrossFileApp {
  init() {
    let cogs = Cogs.assemble()
    cogs.selectCurrentLocation(.newYork)
  }
}
```
