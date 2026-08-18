# ``Cog``

Fine-grained state for SwiftUI: declare what your app knows, read it where you
need it, and let Cog update only what actually changed.

## Overview

Cog keeps one graph of state for your whole app. You declare each fact once,
derive the rest from it, and read values wherever you need them. When something
changes, Cog settles exactly the values that depend on it and notifies exactly
the views that read them. Nothing else runs.

```swift
let temperatureSourceCog = ManualCog<Int>(60)
let adviceCog = Cog<String> { c in
  c[temperatureSourceCog] > 70 ? "shorts" : "coat"
}

struct AdviceLabel: View {
  @Environment(\.cogs) private var cogs

  var body: some View {
    let advice = cogs[adviceCog]
    Text(advice)
  }
}
```

`adviceCog` runs the first time something reads it, and again only when the
temperature it read actually changes. A write of the same temperature settles
nothing and redraws nothing.

Three ideas carry most of the library:

- **A declaration is not state.** ``ManualCog``, ``Cog``, and ``AsyncCog`` are
  lightweight names. The values behind them live in one ``Cogs``, created
  lazily on first use, so declaring costs nothing and the same declaration can
  name state in a test, a preview, and the app.
- **Reads say what they are.** Inside a selector or a mechanism you read
  through the capability you were handed — `c[someCog]` records a dependency,
  `c.peek(someCog)` deliberately does not. In a view, `cogs[someCog]` is the
  tracked read and `cogs.peek(someCog)` the one-shot. You can see a
  computation's dependency set by reading it.
- **Writes happen in turns.** ``Cogs/commit(_:_:)`` is the only way in. Every
  write in one commit crosses the boundary together, so a view that reads two
  values that changed together never renders a torn pair.

### Where to go next

<doc:GettingStarted> takes an app from an empty `Package.swift` to a value on
screen. <doc:OneGraph> explains why an app has exactly one graph, and what that
means for tests and previews. <doc:LintingYourApp> makes Cog's conventions
build-time checks. <doc:StreamsAndExternalState> shows how async sequences and
external Observation values cross the graph boundary.

### Prior art

Cog's graph algorithms follow the SolidJS and Reactively lineage. Its shape as
a Swift library — a dependency graph with dirty marking, recomputation deferred
to the read that needs it, and meeting SwiftUI at `@Observable` rather than
replacing it — was arrived at first by
[swift-state-graph](https://github.com/VergeGroup/swift-state-graph), by
Hiroshi Kimura (muukii) and the VergeGroup authors. Cog diverges deliberately:
one app-wide context owns every state, the reader is a value passed to a
selector rather than ambient tracking, lifetime is declared per state kind,
boxes make keyed value references from one declaration, and async state is a
first-class kind with its own status and policies.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:OneGraph>

### Declaring state

- ``ManualCog``
- ``Cog``
- ``AsyncCog``
- ``ManualCogLifetime``

### Declaring keyed state

- ``ManualCogBox``
- ``CogBox``
- ``AsyncCogBox``

### Sharing state without sharing write access

- ``CogProjection``
- ``CogBoxProjection``

### The runtime

- ``Cogs``
- ``CogOps``

### Reading and writing

- ``Reader``
- ``ReactionReader``
- ``Writer``

### Async state

- ``CogStatus``
- ``Work``
- ``RunWork``
- ``LatestPolicy``
- ``OrderedPolicy``
- ``CogRefresh``

### Moving state across boundaries

- <doc:StreamsAndExternalState>
- ``CogValues``
- ``CogValuesBuffering``

### Side effects

- ``Mechanism``
- ``MechanismController``

### Cog conventions

- <doc:LintingYourApp>
- <doc:CogDeclarationSuffix>
- <doc:NoCogsInViewInit>
- <doc:PrimitivesOnlyInOps>
- <doc:InitialStateInMechanism>
- <doc:ManualCogPrivate>
- <doc:NoMultiReadCogsHelper>
- ``CogWatchStart``
