# manual-cog-private

A recognized `ManualCog` or `ManualCogBox` source has wider access than `private` or `fileprivate`.

## Why this rule exists

Cog state is singular, so each mutable fact has one writable source owned by the file that defines it. Exporting the manual declaration exports a writer target and lets unrelated code bypass the named domain operations that explain who may change that fact.

## How to fix it

Narrow the writable source to `private` or `fileprivate`. When another file needs to read it, expose the source's `.readOnly` projection or a genuinely derived cog instead of the manual declaration itself.

<!-- Generated from the manual-cog-private CogLint fixture corpus; do not edit. -->

## Triggering examples

### Implicit internal access

A bare source declaration is internal and exposes a writer target.

Expected diagnostic positions: 1:5.

```swift
let countSourceCog = ManualCog(0)
```

### Explicit wider access

Internal, package, and public source names all cross the owning file boundary.

Expected diagnostic positions: 1:14, 2:13, 3:12.

```swift
internal let retrySourceCog: Cog.ManualCog<Int> = .init(0)
package let reportSourceCogs = ManualCogBox<String?, Int>(nil)
public let sessionSourceCog = ManualCog("")
```

### Setter-only privacy

`private(set)` leaves the source name visible at its wider read access.

Expected diagnostic positions: 1:25.

```swift
public private(set) var sessionSourceCog = ManualCog("")
```

## Non-triggering examples

### File-owned sources and public reads

Bare private access owns writer targets, while derived and read-only names may remain wider.

```swift
private let countSourceCog = ManualCog(0)
fileprivate let reportSourceCogs = ManualCogBox<String?, Int>(nil)
let countCog = countSourceCog.readOnly
let doubledCog = Cog<Int> { c in c[countCog] * 2 }
```

## Accepted evasions

### Syntax-hidden source identity

Factories, typealiases, and the sanctioned seed re-export do not spell a new manual declaration.

```swift
typealias Source = ManualCog<Int>
private let countSourceCog = ManualCog(0)
let factorySourceCog = makeSource()
let aliasSourceCog = Source(0)
#if DEBUG
let countSeedTargetCog = countSourceCog
#endif
```
