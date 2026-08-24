# cog-declaration-suffix

A recognized Cog declaration must end in `Cog` for a keyless reference or `Cogs` for a keyed box.

## Why this rule exists

The suffix makes reference shape visible at every use and keeps narrower qualifiers such as `Async` or a domain role before the common ending. A reader can therefore distinguish a declaration from an ordinary domain value and know whether it needs a key without chasing its type.

## How to fix it

Rename the declaration so its final word matches its shape. For example, change `_weatherCogDraft` to `_weatherDraftCog`, and change a `CogBox.Manual` named `_reportCog` to `_reportCogs`.

<!-- Generated from the cog-declaration-suffix CogLint fixture corpus; do not edit. -->

## Triggering examples

### Missing and misplaced suffixes

A recognized declaration must finish with its shape suffix, after every narrower qualifier.

Expected diagnostic positions: 1:5, 2:5, 3:5.

```swift
let temperature = Cog<Int> { _ in 0 }
let _weatherCogDraft = Cog.Manual { 0 }
let forecastCogsAsync = Cog<String>.Async(default: "") { _ in fatalError() }
```

### Wrong shape plurality

Keyless references use singular `Cog`; boxes use plural `Cogs`.

Expected diagnostic positions: 1:5, 2:5, 3:5.

```swift
let selectedCogs = Cog<Int> { _ in 0 }
let _reportCog = CogBox<String, Int>.Manual { 0 }
let _avatarCog: CogBox<String, Data> = .init { _ in Data() }
```

## Non-triggering examples

### Shape suffixes after qualifiers

Keyless and boxed declarations end in their singular or plural suffix after role qualifiers.

```swift
let temperatureCog = Cog<Int> { _ in 0 }
private let _weatherServiceCog = Cog.Manual { 0 }
let weatherServiceCog = _weatherServiceCog.readOnly
let forecastAsyncCog = Cog<String>.Async(default: "") { _ in fatalError() }
private let _weatherReportCogs = CogBox<String, Int>.Manual { 0 }
let weatherReportCogs = _weatherReportCogs.readOnly
let forecastAsyncCogs = CogBox<String, Int>.Async(default: "") { _, _ in fatalError() }
```

## Accepted evasions

### Syntax-hidden declaration shape

Factories, typealiases, and cross-file identity remain outside the shared syntax-only classifier.

```swift
typealias Source = Cog<Int>.Manual
let factory = makeSource()
let alias = Source { 0 }
let external = externallyDeclaredReference
```
