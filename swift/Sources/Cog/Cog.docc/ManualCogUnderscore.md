# manual-cog-underscore

A recognized `Cog.Manual` or `CogBox.Manual` declaration name lacks its leading underscore, or a `.readOnly` projection is not named exactly its source's name without the underscore.

## Why this rule exists

The published projection is the name the rest of the app reads, so it owns the clean domain spelling, and the leading underscore marks the file-owned writable source beside it. Pairing the two names exactly keeps one fact's source and published reference recognizable as one pair at a glance, instead of letting a tweaked source qualifier drift away from the name every call site uses.

## How to fix it

Prefix the manual declaration with `_` and name its `.readOnly` projection the same identifier without the underscore: `private let _countCog = Cog.Manual { 0 }` published as `let countCog = _countCog.readOnly`.

<!-- Generated from the manual-cog-underscore CogLint fixture corpus; do not edit. -->

## Triggering examples

### Sources without the leading underscore

Keyless and boxed manual declarations must both begin with `_`.

Expected diagnostic positions: 1:13, 2:13.

```swift
private let countCog = Cog.Manual { 0 }
private let reportCogs = CogBox<String?, Int>.Manual { nil }
```

### Retired Source qualifier pair

The former `Source` spelling violates both halves: the source lacks its underscore and the projection no longer matches it.

Expected diagnostic positions: 1:13, 2:5.

```swift
private let countSourceCog = Cog.Manual { 0 }
let countCog = countSourceCog.readOnly
```

### Renamed projection

A projection may not publish a different domain name than its source states.

Expected diagnostic positions: 2:5.

```swift
private let _countCog = Cog.Manual { 0 }
let totalCog = _countCog.readOnly
```

## Non-triggering examples

### Underscored sources and exactly paired projections

Each projection drops exactly the underscore, and an unprojected underscored source is accepted.

```swift
private let _countCog = Cog.Manual { 0 }
let countCog = _countCog.readOnly
private let _reportCogs = CogBox<String?, Int>.Manual { nil }
let reportCogs = _reportCogs.readOnly
private let _draftCog = Cog.Manual { "" }
```

## Accepted evasions

### Syntax-hidden source identity

Aliases, factories, and copies stay outside the syntax-only classifier, so a projection of a copied source cannot be paired.

```swift
typealias Source = Cog<Int>.Manual
let aliasCog = Source { 0 }
let factoryCog = makeSource()
private let _countCog = Cog.Manual { 0 }
let copiedCog = _countCog
let renamedCog = copiedCog.readOnly
```
