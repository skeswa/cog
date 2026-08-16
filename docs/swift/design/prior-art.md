# Cog for Swift: prior-art review and public-name decisions

_August 16, 2026_

This is the record of `M4-01a`: a time-boxed review of
[swift-state-graph](https://github.com/VergeGroup/swift-state-graph) read
before freezing Cog's public names for 0.1.0, the tracked-read comparison the
plan asks for, and the resulting decision matrix. The plan's charter is
"[r]ead swift-state-graph source before freezing public names; credit prior
art; compare tracked reads with capture lists. Adjust names if warranted"
([plan.md](../impl/plan.md), M4).

`M4-01b` applies whatever delta section 5 proposes and lands the matching §10,
snapshot, and attribution edits.

## 1. What was reviewed

swift-state-graph, by [Hiroshi Kimura (muukii)](https://github.com/muukii) and
the [VergeGroup](https://github.com/VergeGroup) authors: "a next-generation
graph-based state management library for SwiftUI and UIKit. Compatible with
`@Observable`."

Read within the time box:

- the repository README and the `Documentation.docc` UIKit integration
  article;
- `Sources/StateGraph/Primitives/Node.swift` — the node protocols, edge
  storage, and dirty marking;
- `Sources/StateGraph/Primitives/StateGraph.swift` — `Computed`, its `Context`,
  and the dependency-recording path;
- the file inventory of `Sources/StateGraph/` and
  `Sources/StateGraph/Primitives/`.

Not read, and therefore not claimed about here: the macro implementations, the
`UserDefaults` backing, the transaction coordinator, the SwiftUI environment
propagation, and the test suite. Nothing in section 5 depends on those.

## 2. How the two libraries line up

| Concern            | swift-state-graph                                                               | Cog                                                                              |
| ------------------ | ------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| Declaration        | `@GraphStored` / `@GraphComputed` property wrappers, plus macros                | Value references — `ManualCog`, `Cog`, `AsyncCog` — and boxes; no macros (§2.3)  |
| Where state lives  | On the objects that declare it; nodes live as long as something references them | One app-wide `Cogs` owns every state under descriptor-and-key identity (§3.1)    |
| Dependency capture | Ambient: a thread-local current node, recorded when a node is read              | Explicit: reads through the `Reader` passed to the selector (§2.4)               |
| Invalidation       | `potentiallyDirty` flag plus `recomputeIfNeeded()`                              | CLEAN/CHECK/DIRTY with versions and equality gates (§2.2)                        |
| Node identity      | Class instances; edges held on both ends                                        | Descriptor `ObjectIdentifier` plus key; edges recaptured every run (§2.3, §2.4)  |
| Reactions          | `withGraphTracking { }` returning an `AnyCancellable` the caller must retain    | Bootstrap-registered mechanisms; no late registration, no caller-held token (§6) |
| Async state        | none of its own                                                                 | `AsyncCog`, `CogStatus`, `Work`, policies (§5.1, §5.2)                           |
| Lifetime           | ARC: a node lives while something holds it                                      | Declared per kind: `.app`, `.whileObserved(grace:)` (§5.3)                       |
| Keyed state        | none                                                                            | Boxes make per-key value references from one declaration (§3.1)                  |
| UI boundary        | `@Observable`-compatible                                                        | `@Observable`-compatible; one boundary object per UI-read state (§7)             |

The convergent parts — a dependency graph, dirty marking, lazy recomputation
at read, and meeting SwiftUI at `@Observable` rather than replacing it — are
the parts both libraries inherit from the same lineage that
[perf.md](./perf.md) already credits. The divergent parts are ownership
(objects versus one context), how a dependency is captured, and whether async
and lifetime are the library's business.

## 3. Tracked reads versus capture lists

This is the comparison the plan asked for, and it has a trap in it worth
recording.

swift-state-graph's documented examples _look_ like capture lists declare the
dependencies:

```swift
self.$filteredTodos = .init { [$todos, $filter] _ in
  $todos.wrappedValue.filter { ... }
}
```

They do not. The capture list is ordinary Swift closure capture — it brings the
node references into a `@Sendable` closure without capturing `self`. The
dependency is recorded by the read itself, through a thread-local:

```swift
// record dependency
if let currentNode = ThreadLocal.currentNode.value {
  let edge = Edge(from: self, to: currentNode)
  outgoingEdges.append(edge)
  currentNode.incomingEdges.append(edge)
}
```

So both libraries capture dependencies dynamically, on every run, from actual
reads. The real difference is where "who is reading" lives: swift-state-graph
keeps it in ambient thread-local state, while Cog passes it as a value — the
`Reader` a selector receives, spelled `c` at the call site.

Cog keeps the explicit reader, for reasons that are the project's existing
principles rather than novelty:

- **The graph edge is visible in the source.** `c[otherCog]` is tracked and
  `c.peek(otherCog)` is not, so a reviewer can see a selector's dependency set
  by reading it. Ambient tracking makes an untracked read a
  `withoutTracking { }` scope — an opt-out that is easy to forget and invisible
  at the read itself.
- **A read outside a computation cannot silently become a dependency.** With no
  ambient reader there is nothing to accidentally attach to. Cog's failure
  mode is a compile error (no `c` in scope), not a mistracked edge.
- **No thread-local on the hot path.** Cog's tracking slot is MainActor-confined
  context state, which the data-oriented core (perf §3–§8) needs anyway.
- **Isolation.** Cog is MainActor-confined by construction; thread-local
  tracking exists to make ambient state work across executors, which Cog does
  not need.

The cost is real and should be stated: an explicit reader is one more parameter
in every selector, and it makes a plain Swift function unusable as a selector
body unless it takes a reader too. Cog accepts that; it is the same trade the
`Writer` makes for commits, and it keeps both capabilities unforgeable.

## 4. What Cog should borrow

Nothing structural. Two smaller notes:

- swift-state-graph names nodes with `#fileID`, `#line`, **and `#column`**, plus
  an optional `name:`. Cog uses `#fileID` and `#line` only. Column would
  distinguish two declarations on one line, which is rare enough in the
  declaration style Cog documents that it is not worth widening every
  initializer. Recorded, not adopted.
- `Computed.Context` exposes `withoutTracking { }` as a scope. Cog's equivalent
  is per-read (`c.peek`), which is narrower and needs no scope. Keep, and say
  so in the DocC article so readers arriving from swift-state-graph find the
  mapping.

## 5. Public-name decision matrix

Every row is a name that this review actually reconsidered. "Prior art" is what
swift-state-graph calls the nearest thing, where it has one.

| Cog name                                  | Prior art                   | Alternative considered               | Decision                                                                                                                                                                                                                                 |
| ----------------------------------------- | --------------------------- | ------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Cog<T>` (derived)                        | `Computed`                  | `DerivedCog`                         | **Keep.** Derived is the shape most declarations take, so it earns the short name, and `Cog` names the concept the library is about. `Computed` would also be fine, but renaming buys nothing.                                           |
| `ManualCog<T>`                            | `Stored`                    | `SourceCog`, `StoredCog`             | **Keep.** The trio names how a value arrives — written by hand, derived, or awaited — which is the distinction that matters at the declaration. "Source" stays the prose word for the role, as it already is throughout the design docs. |
| `Cogs` (the runtime)                      | `NodeStore`                 | `CogGraph`, `CogRuntime`, `CogStore` | **Keep, with a revisit trigger.** See below.                                                                                                                                                                                             |
| `CogBox` / `ManualCogBox` / `AsyncCogBox` | none                        | `CogFamily`, `KeyedCog`              | **Keep.** A box is a declaration that makes value references, not a collection, and "box" says that without borrowing Recoil's "family".                                                                                                 |
| `Reader` (`c`)                            | `Computed.Context`          | `Context`, `Scope`                   | **Keep.** It reads; it does not write. `Context` is already the most overloaded word in Swift app code, and Cog uses "context" for the runtime in prose.                                                                                 |
| `Writer` (`c`)                            | `GraphTransaction`          | `Transaction`                        | **Keep.** SwiftUI already owns `Transaction`.                                                                                                                                                                                            |
| `commit(_:_:)`                            | transactions                | `mutate`, `update`, `write`          | **Keep.** Settled in §10; the name says the turn boundary is the point.                                                                                                                                                                  |
| `peek(_:)`                                | `withoutTracking { }`       | `untracked`, `read`                  | **Keep.** Per-read, one word, and symmetrical between `c.peek` and `cogs.peek`.                                                                                                                                                          |
| `CogStatus`, `Work`, `LatestPolicy`       | none                        | —                                    | **Keep.** No prior art to align with; `M4-06` and `M4-07a` already settled this surface.                                                                                                                                                 |
| `Mechanism`, `MechanismController`        | `withGraphTracking` + token | `Effect`, `Feature`                  | **Keep.** Deliberately different: registration is bootstrap-only and the runtime owns the lifetime, so there is no cancellable for a caller to drop — which is exactly the failure swift-state-graph's UIKit article warns about twice.  |
| `ManualCogLifetime`                       | none (ARC)                  | `CogLifetime`                        | **Keep.** Only sources take a lifetime argument today; a shared name would promise a knob derived and async cogs do not have.                                                                                                            |
| `.readOnly` / `CogProjection`             | none                        | `.readonly`, `AnyCog`                | **Keep.**                                                                                                                                                                                                                                |
| `bootstrapApp`, `forTesting`              | none                        | —                                    | **Keep.** Settled at `M1-34a` and amended by the mechanism redesign.                                                                                                                                                                     |

### The one uncomfortable name

`Cogs` is both the runtime type and, by the naming convention, the suffix every
box declaration carries. A view can legitimately contain:

```swift
let report = cogs[weatherReportSourceCogs[zip]]
```

where the first `cogs` is the runtime and the second is a keyed declaration.
Kotlin, which is not bound by this decision, calls the same concept
`CogStore` — so cross-platform vocabulary is an argument against `Cogs` too.

It stays, for three reasons. The spelling is settled in §10 across several
rows — the one-context rule, context construction, and the bootstrap helper
names settled at `M1-34a` — and the box suffix was chosen knowingly beside it.
`CLAUDE.md` and `AGENTS.md` already carry the disambiguation: the runtime is
always the ordinary local `cogs`, and box declarations always carry a narrower
qualifier before the suffix, so the two never collide as bare words. And the
rename would touch every document, scenario, and test in the repository on the
eve of a release whose whole point is to get Cog into an app.

Revisit trigger for a future review: if two or more people reading Cog code for
the first time misread `cogs` for a declaration, or if the Kotlin package ships
with `CogStore` and the divergence shows up in shared documentation, reopen
this as a 1.0 rename with its own task.

## 6. Proposed API delta for `M4-01b`

**No public renames.** The delta is attribution and one documentation
obligation:

1. Add a prior-art credit to `docs/swift/README.md` and the §10 record naming
   swift-state-graph, its authors, and what Cog independently converged on
   (graph plus dirty marking plus lazy pull, and meeting SwiftUI at
   `@Observable`), while naming the deliberate divergences: one app-wide
   context, an explicit reader instead of ambient tracking, declared lifetimes,
   keyed boxes, and async as a first-class state kind.
2. Record in §10 that the public-name review ran and changed nothing, with a
   pointer to this file, so the freeze is a decision rather than an omission.
3. Carry the `withoutTracking { }` → `peek` mapping and the "capture lists are
   not the dependency mechanism" clarification into the DocC article `M4-03`
   writes, for readers arriving from swift-state-graph.

The DocC landing page (`M4-02`) is the natural home for item 1's short form.
