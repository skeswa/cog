# primitives-only-in-ops

Production code calls `turn` or `refresh` outside a bare primitive call in an `extension CogOps` domain operation.

## Why this rule exists

Graph primitives describe how Cog performs work, not what the application is asking for. Named operations keep the domain verb beside its state declarations, give every call site one readable intent, and apply the same boundary to views, mechanisms, selectors, writers, and runtime helpers.

## How to fix it

Move the primitive into a named method on `CogOps`, spell `turn(...)` or `refresh(...)` bare there, and call that domain method through the capability at the original site. Tests may select the explicit test target role when they need to drive primitives directly.

<!-- Generated from the primitives-only-in-ops CogLint fixture corpus; do not edit. -->

## Triggering examples

### Environment and assembly primitives

View and assembly graph receivers must call domain operations instead of primitives.

Expected diagnostic positions: 4:10, 5:15, 10:12, 11:12.

```swift
struct CounterCard: View {
  @Environment(\.cogs) private var cogs
  func increment() {
    cogs.turn { c in c[_countCog] += 1 }
    self.cogs.refresh(forecastCog)
  }
}
func launch() {
  let appGraph = Cogs.assemble()
  appGraph.turn(_countCog, to: 1)
  appGraph.refresh(forecastCog)
}
```

### Reader writer and mechanism primitives

Every classifier-proven capability stays behind the same named-operation boundary.

Expected diagnostic positions: 1:36, 2:33, 5:7, 6:7, 7:20, 8:45.

```swift
let invalidCog = Cog<Int> { c in c.refresh(forecastCog); return 0 }
func overwrite(_ c: Writer) { c.turn(named: "nested") { _ in } }
struct Loader: Mechanism {
  func operate(_ m: MechanismController) {
    m.turn(_countCog, to: 1)
    m.refresh(forecastCog)
    m.run { c in c.refresh(forecastCog) }
    m.whenever(enabledCog) { child in child.turn(_countCog, to: 2) }
  }
}
```

### Runtime extension primitives

A `Cogs` extension cannot disguise a primitive as an application helper.

Expected diagnostic positions: 3:5, 4:10, 8:34.

```swift
extension Cogs {
  func resetInline() {
    turn(_countCog, to: 0)
    self.refresh(forecastCog)
  }
}
extension CogOps {
  func wronglyQualified() { self.turn(_countCog, to: 0) }
}
```

## Non-triggering examples

### Bare primitives inside named operations

A `CogOps` extension may use bare primitives through nested writer and helper closures.

```swift
extension CogOps {
  func selectCount(_ value: Int) {
    turn(_countCog, to: value)
    turn { c in
      c[_countCog] = value
      withAnimation { turn(_otherCog, to: value) }
    }
  }
  func refreshForecast() { refresh(forecastCog) }
}
struct CounterCard: View {
  @Environment(\.cogs) private var cogs
  func increment() { cogs.selectCount(1) }
}
```

### Unrelated method names

Calls on unclassified values do not become Cog primitives by spelling alone.

```swift
func update(cache: Cache) {
  cache.turn()
  cache.refresh()
}
```

## Accepted evasions

### Syntax-hidden graph capability

Factories and typealiases that hide receiver identity remain outside the syntax-only classifier.

```swift
typealias Controller = MechanismController
func hidden(_ controller: Controller) { controller.turn(_countCog, to: 1) }
func inferred() {
  let graph = makeCogs()
  graph.refresh(forecastCog)
}
```
