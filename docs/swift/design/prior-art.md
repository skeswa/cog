# Cog for Swift: prior-art review

_August 16, 2026_

This review compares Cog with
[swift-state-graph](https://github.com/VergeGroup/swift-state-graph), by Hiroshi
Kimura and the VergeGroup authors. It explains why Cog kept its public names
before the 0.1.0 API freeze. No knowledge of that library is required.

The review covered its public guide, UIKit article, node and graph code, edge
storage, dirty marking, and dependency tracking. It did not review its macros,
transactions, persistence, SwiftUI environment code, or tests.

## 1. Main differences

| Concern      | swift-state-graph             | Cog                                                 |
| ------------ | ----------------------------- | --------------------------------------------------- |
| Declarations | Property wrappers and macros  | Value references and keyed boxes                    |
| State owner  | Each declaring object         | One app-wide `Cogs`                                 |
| Tracked read | Ambient thread-local state    | An explicit `Reader` passed to each selector        |
| Invalidation | Dirty flag and lazy recompute | CLEAN, CHECK, and DIRTY with versions and equality  |
| Identity     | Node objects                  | Descriptor identity plus key                        |
| Reactions    | Caller-owned cancellable      | Assembly-owned mechanisms                           |
| Async state  | No built-in form              | `Cog<T>.Async`, `CogStatus`, `Work`, and policies   |
| Lifetime     | ARC                           | A declared app or observed lifetime                 |
| Keyed state  | No built-in form              | Boxes                                               |
| UI boundary  | Works with `@Observable`      | One `@Observable` boundary per state read by the UI |

Both libraries use a graph, mark dirty state, recompute on demand, and work
with SwiftUI's Observation system. Cog differs in ownership, tracked-read
syntax, lifetime, keyed state, and async state.

## 2. Why Cog uses an explicit reader

swift-state-graph examples use closure capture lists, but the captures do not
declare dependencies. Reads record dependencies through a thread-local current
node. Both libraries therefore rebuild edges from actual reads on every run.

Cog passes a `Reader`, usually named `c`, into the selector instead:

- `c[otherCog]` clearly adds a dependency; `c.peek(otherCog)` clearly does not.
- Code outside a selector cannot add an edge by accident because it has no
  reader.
- Tracking needs no thread-local lookup on Cog's MainActor hot path.
- The same capability model gives turns a limited `Writer`.

The cost is one extra selector parameter. A normal Swift function must accept a
reader before it can serve as a selector body. Cog accepts that cost because the
dependency stays visible and cannot be forged.

## 3. Small ideas considered

swift-state-graph includes `#column` in an unnamed node's source location. Cog
uses `#fileID` and `#line`. Two declarations on one line are rare, so Cog did
not widen every initializer for the extra field.

swift-state-graph uses `withoutTracking { }`. Cog keeps the smaller per-read
form, `peek`, so the untracked choice is visible at the read.

## 4. Public-name decisions

| Cog name                           | Other name considered                     | Decision                                                                                                                                                                                                                                                                                                                                                                                               |
| ---------------------------------- | ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `Cog<T>`                           | `Computed`, `DerivedCog`                  | Keep the short name for the common automatic form.                                                                                                                                                                                                                                                                                                                                                     |
| `Cog<T>.Manual`                    | `ManualCog<T>`, `StoredCog`, `SourceCog`  | Uphold the manual, automatic, and async naming set while moving the shape from a prefix to a nested family member. `.Manual` names the mechanism; a declaration variable begins with a leading underscore, and its `.readOnly` projection takes the same name without it (the former `Source` role qualifier is retired). The prefixed spelling is removed rather than retained as a deprecated alias. |
| `Cogs`                             | `CogGraph`, `CogRuntime`, `CogStore`      | Keep, with the review trigger below.                                                                                                                                                                                                                                                                                                                                                                   |
| `CogBox` family                    | `CogFamily`, `KeyedCog`                   | A box creates value references; it is not a collection. Its manual, async, and projection shapes are nested members matching `Cog`.                                                                                                                                                                                                                                                                    |
| `Reader`                           | `Context`, `Scope`                        | It reads only. `Context` is already too broad.                                                                                                                                                                                                                                                                                                                                                         |
| `Writer`                           | `Transaction`                             | SwiftUI already uses `Transaction`.                                                                                                                                                                                                                                                                                                                                                                    |
| `turn`                             | `mutate`, `update`, `write`               | It names Cog's atomic graph boundary.                                                                                                                                                                                                                                                                                                                                                                  |
| `peek`                             | `untracked`, `read`                       | It is short and matches both reader and runtime APIs.                                                                                                                                                                                                                                                                                                                                                  |
| `CogStatus`, `Work`, policy types  | —                                         | No matching prior-art API called for a rename.                                                                                                                                                                                                                                                                                                                                                         |
| `Mechanism`, `MechanismController` | `Effect`, `Feature`                       | Assembly owns registration and lifetime; callers hold no token.                                                                                                                                                                                                                                                                                                                                        |
| `ManualCogLifetime`                | `CogLifetime`                             | Keep it top-level: the policy is value-independent and shared by keyless and box families.                                                                                                                                                                                                                                                                                                             |
| `.readOnly`, `Cog<T>.Projection`   | `.readonly`, `AnyCog`, `CogProjection<T>` | Keep the property name and move the wrapper into the same nested shape family.                                                                                                                                                                                                                                                                                                                         |
| `assemble`, `forTesting`           | `bootstrapApp`                            | The names state which runtime each factory creates. `assemble` replaced `bootstrapApp`: API names reference the `Cogs` object, never the "app", so the testing inspectors are `withAssembledCogs`, `isAssembledCogs`, and `hasAssembledCogs`. The old spellings are removed rather than deprecated.                                                                                                    |

### The `Cogs` name

`Cogs` is the runtime type and the suffix for a box declaration:

```swift
let report = cogs[_weatherReportCogs[zip]]
```

The local `cogs` is the runtime. The underscored `_weatherReportCogs` is a
box. The naming rule keeps them clear in normal code. Renaming the runtime
would touch the whole API and docs without changing behavior.

Revisit this for 1.0 if at least two new readers confuse the runtime with a box,
or if Kotlin ships `CogStore` and the split harms shared documentation.

## 5. Outcome

The 0.1.0 review caused no public rename. The later shape-family decision
upheld its manual/automatic/async vocabulary while moving the marked shapes
from prefixes to nested members. The type names the mechanism axis —
`.Manual` — while declaration variables may name their source role. Cog also
removed the prefixed spellings instead of carrying deprecated aliases, added
the prior-art credit, documented the `withoutTracking { }` to `peek` mapping,
and made clear that capture lists do not create dependencies.
