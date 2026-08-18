# cog-declaration-suffix

A recognized Cog declaration must end in `Cog` for a keyless reference or `Cogs` for a keyed box.

## Why this rule exists

The suffix makes reference shape visible at every use and keeps narrower qualifiers such as `Source`, `Async`, or a domain role before the common ending. A reader can therefore distinguish a declaration from an ordinary domain value and know whether it needs a key without chasing its type.

## How to fix it

Rename the declaration so its final word matches its shape. For example, change `weatherCogSource` to `weatherSourceCog`, and change a `ManualCogBox` named `reportCog` to `reportCogs`.

<!-- Generated from the cog-declaration-suffix CogLint fixture corpus; do not edit. -->

## Triggering examples

### Missing and misplaced suffixes

A recognized declaration must finish with its shape suffix, after every narrower qualifier.

Expected diagnostic positions: 1:5, 2:5, 3:5.

```swift
let temperature = Cog<Int> { _ in 0 }
let weatherCogSource = ManualCog(0)
let forecastCogsAsync = AsyncCog<String> { _ in "" }
```

### Wrong shape plurality

Keyless references use singular `Cog`; boxes use plural `Cogs`.

Expected diagnostic positions: 1:5, 2:5, 3:5.

```swift
let selectedCogs = Cog<Int> { _ in 0 }
let reportCog = ManualCogBox<String, Int>(0)
let avatarCog: CogBox<String, Data> = .init { _ in Data() }
```

## Non-triggering examples

### Shape suffixes after qualifiers

Keyless and boxed declarations end in their singular or plural suffix after role qualifiers.

```swift
let temperatureCog = Cog<Int> { _ in 0 }
private let weatherServiceSourceCog = ManualCog(0)
let weatherServiceCog = weatherServiceSourceCog.readOnly
let forecastAsyncCog = AsyncCog<String> { _ in "" }
private let weatherReportSourceCogs = ManualCogBox<String, Int>(0)
let weatherReportCogs = weatherReportSourceCogs.readOnly
let forecastAsyncCogs = AsyncCogBox<String, Int> { _ in 0 }
```

## Accepted evasions

### Syntax-hidden declaration shape

Factories, typealiases, and cross-file identity remain outside the shared syntax-only classifier.

```swift
typealias Source = ManualCog<Int>
let factory = makeSource()
let alias = Source(0)
let external = externallyDeclaredReference
```
