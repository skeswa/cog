# no-cogs-in-view-init

A recognized SwiftUI view must not store `Cogs` or accept it through an initializer or method parameter.

## Why this rule exists

Production has one app-wide runtime installed at the scene boundary. Resolving it independently in every consumer prevents views from forwarding graph ownership, creating hidden composition boundaries, or making an initializer appear to choose which state graph is authoritative.

## How to fix it

Declare `@Environment(\.cogs) private var cogs` in each view that reads or operates on Cog. Pass domain values and identities between views, and keep explicit `Cogs` parameters only at non-view boundaries such as isolated test harnesses.

<!-- Generated from the no-cogs-in-view-init CogLint fixture corpus; do not edit. -->

## Triggering examples

### Stored graph runtime

A recognized view must resolve the runtime from its environment instead of storing it.

Expected diagnostic positions: 2:13, 3:24, 4:30.

```swift
struct Dashboard: View {
  let cogs: Cogs
  var optionalRuntime: Cogs?
  var wrappedRuntime: Holder<Cogs>
  var body: some View { EmptyView() }
}
```

### Initializer and method forwarding

Initializer and method parameters cannot carry `Cogs`, even through optional or generic types.

Expected diagnostic positions: 3:33, 4:37.

```swift
struct Dashboard { var body: some View { EmptyView() } }
extension Dashboard {
  init(cogs: Swift.Optional<Cog.Cogs>) {}
  func render(using runtime: Result<Cogs, Error>) {}
}
```

## Non-triggering examples

### Environment-owned graph access

Each view resolves `cogs` itself and accepts only domain values and identities.

```swift
struct Dashboard: View {
  @Environment(\.cogs) private var cogs
  let accountID: Account.ID
  init(accountID: Account.ID) { self.accountID = accountID }
  func title(for account: Account) -> String { account.name }
  var body: some View { EmptyView() }
}
```

## Accepted evasions

### Syntax-hidden view or runtime identity

Inferred runtime values, aliases, and cross-file view conformance remain outside syntax-only recognition.

```swift
typealias Runtime = Cogs
struct ExternalView {
  let inferred = makeCogs()
  let aliased: Runtime
  let written: Cogs
}
```
