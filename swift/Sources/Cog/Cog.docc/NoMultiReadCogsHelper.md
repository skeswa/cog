# no-multi-read-cogs-helper

A value-returning member of `extension Cogs` or `extension CogOps` contains two or more immediate graph reads.

## Why this rule exists

Reads in one consumer already come from one settled turn and register independently for precise invalidation. Repackaging several reads behind a runtime helper hides the consumer's dependencies, invites the projection to be stored or forwarded, and adds a type without improving consistency.

## How to fix it

Read each value flatly on its own line at the consuming boundary. If the combined value is real derived state rather than values merely used together, declare a derived cog and read that single declaration instead.

<!-- Generated from the no-multi-read-cogs-helper CogLint fixture corpus; do not edit. -->

## Triggering examples

### Value and status repackaging

A value helper cannot hide two direct tracked reads behind one returned projection.

Expected diagnostic positions: 2:8, 7:7.

```swift
extension Cogs {
  func weatherCardReading(for zip: Zip) -> WeatherCardReading {
    let forecast = self[weatherForecastCogs[zip]]
    let selection = self[currentZipCodeCog]
    return WeatherCardReading(forecast: forecast, selection: selection)
  }
  var currentForecast: ForecastSummary {
    let forecast = status[forecastCog]
    let place = self.status[placeCog]
    return ForecastSummary(forecast: forecast, place: place)
  }
}
```

### Peek helpers on both operation capabilities

Bare, self-qualified, and status peeks are direct graph reads by spelling.

Expected diagnostic positions: 2:8, 7:3.

```swift
extension CogOps {
  func pair() -> Pair {
    Pair(first: peek(firstCog), second: self.peek(secondCog))
  }
}
extension Cogs {
  subscript(snapshot key: Key) -> Snapshot {
    get { Snapshot(value: peek(valuesCogs[key]), status: status.peek(statusCogs[key])) }
  }
}
```

## Non-triggering examples

### One direct read per value helper

A narrow helper exposing one graph read does not repackage several dependencies.

```swift
extension Cogs {
  func selectedZip() -> Zip? { peek(selectedZipCog) }
  var currentCount: Int { self[countCog] }
}
```

### Excluded member returns and nested closures

Void, view, binding, and closure-contained reads stay outside the exact value-helper rule.

```swift
extension Cogs {
  func inspect() { _ = self[firstCog]; _ = self[secondCog] }
  func reset() -> Void { _ = peek(firstCog); _ = peek(secondCog) }
  func clear() -> () { _ = status[firstCog]; _ = status[secondCog] }
  func card() -> some View { Text("\(self[firstCog]) \(self[secondCog])") }
  func erasedCard() -> SwiftUI.View {
    _ = self[firstCog]
    _ = self[secondCog]
    return EmptyView()
  }
  var binding: Binding<Int> {
    let first = self[firstCog]
    let second = self[secondCog]
    return Binding(get: { first + second }, set: { _ in })
  }
  func deferred() -> () -> Pair {
    { Pair(first: self[firstCog], second: self[secondCog]) }
  }
}
```

### Helpers outside graph extensions

The same lexical reads outside exact `Cogs` or `CogOps` extensions are not classified.

```swift
struct ProjectionBuilder {
  func pair(from cogs: Cogs) -> Pair {
    Pair(first: cogs[firstCog], second: cogs[secondCog])
  }
}
```

## Accepted evasions

### Repackaging through helper data flow

Calls to separate one-read helpers require data-flow analysis to identify the combined projection.

```swift
extension Cogs {
  func firstValue() -> Int { self[firstCog] }
  func secondValue() -> Int { self[secondCog] }
  func pair() -> Pair {
    let first = firstValue()
    let second = secondValue()
    return Pair(first: first, second: second)
  }
}
typealias Runtime = Cogs
extension Runtime {
  func hiddenPair() -> Pair { Pair(first: self[firstCog], second: self[secondCog]) }
}
```
