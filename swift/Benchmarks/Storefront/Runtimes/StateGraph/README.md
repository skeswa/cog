# The swift-state-graph Storefront comparison runtime

A separate SwiftPM package named `cog-storefront-state-graph`. It sits beside
the Cog and Observation runtime packages so its external dependency reaches
only consumers that intentionally select this port.

It holds the fourth of the four runtimes the Storefront macrobenchmark compares:
a port of the same workload onto
[swift-state-graph](https://github.com/VergeGroup/swift-state-graph), pinned at
exactly `0.28.0`.

| Target                 | Benchmark slug | What it is                                                          |
| ---------------------- | -------------- | ------------------------------------------------------------------- |
| `StorefrontStateGraph` | `state-graph`  | The workload over swift-state-graph's `Stored` and `Computed` nodes |

It runs the identical eleven-phase interaction trace from `StorefrontWorkload`,
against the identical fixtures, the identical scripted request boundary, and the
identical shadow model as the other three runtimes.

## Why this is a package of its own

Because SwiftPM hands a package's dependencies to **everyone** who resolves it.
If this port shared a package with the two `@Observable` ports in
`swift/Benchmarks/Storefront/Runtimes/Observation`, an `@Observable` comparison
application would resolve swift-state-graph and its macro toolchain along with
the port it actually wanted. That is the identical mistake
[`Workload/README.md`](../../Workload/README.md) documents about the
`cog-benchmarks` **package**, and the answer is the same one: give the
dependency a package of its own so it reaches only the consumers that ask for
it.

It is separate from `cog-storefront` for that reason and for a second: that
package is the worked large-app Cog example and must stay that, and CogLint runs
its sources under the Cog application ruleset, which has no business being
applied to a port that contains no Cog symbol at all.

## Why it stays independent of the runner

`swift/Benchmarks/Runner` owns the ordo-one harness and malloc interposer. This
package does not: the runner consumes its product through a path dependency,
while a future state-graph benchmark application can resolve this package
without resolving the measurement harness.

## Dependencies

```swift
dependencies: [
  .package(path: "../../Workload"),
  .package(url: "https://github.com/VergeGroup/swift-state-graph", exact: "0.28.0"),
]
```

The pin is `exact` rather than a range, matching `swift/Benchmarks/Runner/Package.swift`:
this port is written against the source of one exact release, and a comparison
that silently resolved a different one would be reporting a number about code
nobody read. `Package.resolved` is committed here for the same reason it is
committed there.

## `API-NOTES.md`

Every behavior of 0.28.0 this port rests on was measured, not inferred, and
[`API-NOTES.md`](API-NOTES.md) records each claim with a `file:line` citation and
the probe output that proves it. The headline findings:

- `Computed` memoizes, but **only** when its `Value` is `Equatable` at the call
  site — the non-memoizing overload sits in the same type and binds silently
  otherwise. Every `Value` in this port must therefore be `Equatable`.
- `withGraphTransaction` buys atomic visibility, read-your-own-staged-writes, one
  notification wave, and rollback. It does **not** buy coalescing: `Computed` is
  pull-based, so coalescing is a property of reading once. Verbs use it on
  correctness grounds.
- Reading a `Computed` **inside** a transaction re-evaluates its whole rule and
  never updates the cache, so the port reads derived values only after the
  transaction commits.
- There is no keyed-node facility; the per-key dictionary and its eviction policy
  are the port's own.
- The definite settlement signal is the read itself. Tracking re-application is
  deferred to the next event loop and cannot be a settlement barrier, so the port
  renders explicitly.

## `Probes/APIBehavior/`

A nested throwaway SwiftPM package that produced the measurements above. It lives
here rather than beside this package because it had to resolve swift-state-graph
before this package existed. It is outside every target's `path:`, so SwiftPM
never compiles it as part of this package; its own `Package.swift` and
`Package.resolved` are its own business.

```sh
swift run --package-path swift/Benchmarks/Storefront/Runtimes/StateGraph/Probes/APIBehavior sgprobe
```

## Build settings

`storefrontSwiftSettings` in `Package.swift` is copied **verbatim** from
`swift/Benchmarks/Storefront/Workload/Package.swift` and must stay byte-identical to it. A comparison
whose runtimes were compiled under different isolation or language-mode settings
would be measuring the settings rather than the runtimes. It is copied rather
than shared because SwiftPM manifests cannot import one another, and
`StorefrontBuildShapeTests` in the `Verification` package asserts that all four
runtime manifests agree.

## What the port is

`StateGraphStorefrontRuntime` conforms to `StorefrontRuntime` and is driven by
the shared `StorefrontSessionDriver`, so it performs the same shopping session as
the Cog reference rather than a similar one. Three source files:

| File                                | What it holds                                                                                                                                                                                                                                                                                                                    |
| ----------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `StorefrontStateGraphNodes.swift`   | The derivation graph: eleven `Stored` sources, five keyed source tables, seven keyless and three keyed accepted-value nodes, eighteen keyless `Computed` values, eight keyed `Computed` families including the full seventeen-stage pricing ladder per price book per product, and one `Computed` selector per asynchronous slot |
| `StorefrontStateGraphAsync.swift`   | The port-authored asynchronous layer: slot keys, request plans, generations, and the per-generation demand handle                                                                                                                                                                                                                |
| `StorefrontStateGraphRuntime.swift` | The verbs, the transaction boundary, the settlement, the explicit render, the request epilogue, the release sweep, and the two settlement barriers                                                                                                                                                                               |

Nothing is precomputed, nothing is flattened, nothing caches across trace
phases, nothing reads another port, and nothing knows the script. The
derivation graph is a node-for-node, dependency-for-dependency reading of
`swift/Benchmarks/Storefront/Runtimes/CogRuntime/Sources/CogStorefront/StorefrontState.swift`,
`StorefrontAutomatic.swift`, and `StorefrontAsync.swift`.

## Declared semantics, field by field

```swift
StorefrontRuntimeSemantics(
  browseRunsPerContentChangingTurn: 1,
  browseRunsPerEqualWrite: 0,
  browseRunsPerUndemandedInvalidation: 0,
  accountRunsThroughSignIn: 2,
  declaredUndemandedRequestStarts: 0,
  releasesUnobservedValues: true,
  refusesStaleResultsByGeneration: true,
  hasPerGenerationRefreshHandles: true
)
```

- **`browseRunsPerContentChangingTurn: 1`.** Every verb is one
  `withGraphTransaction` followed by one settlement, and a settlement renders
  once. Note what earns this and what does not: the transaction is required for
  atomicity, staged reads, and rollback, but it does **not** coalesce
  recomputation — `Computed` is pull-based, so N writes followed by one read
  produce one recomputation with or without it (`API-NOTES.md` probes `b1`,
  `b2`). _Reading once_ is what produces one settled render.
- **`browseRunsPerEqualWrite: 0`.** Every source is built through
  `makeSource(_:_:)`, whose `Value: Equatable` constraint forces `Stored`'s
  equality-gated initializer, so a write of the current value invalidates
  nothing and the render finds unchanged roots.
- **`browseRunsPerUndemandedInvalidation: 0`.** An invalidation confined to
  offscreen inputs reaches no root the render reads. Because rendering is
  explicit, the port decides that a run happened by comparing what it just read
  against what it last deposited — **output comparison, disclosed here as
  `StorefrontRuntimeSemantics` requires**. The cost of that re-read is inside
  every number this runtime reports, which is the honest place for it.
- **`accountRunsThroughSignIn: 2`.** The account observer runs at registration
  against the resting signed-out value and again when the response lands, and
  never in between — the same shape as Cog's
  `watch(storefrontAccountCog, initial: .run)`.
- **`declaredUndemandedRequestStarts: 0`.** The port polls only demanded slots,
  and demand is the prefetch window, the cart lines, and the open product. An
  inventory burst covering offscreen products advances their generations and
  stops: no plan is read, no request starts.
- **`releasesUnobservedValues: true`.** Earned by a port-authored TTL sweep; see
  below.
- **`refusesStaleResultsByGeneration: true`.** A completion is accepted only when
  it names the generation its slot is currently on. The port never cancels a
  superseded task — it lets it complete and refuses it, which is the stronger
  proof and the one the script is built for.
- **`hasPerGenerationRefreshHandles: true`.** `refreshRecommendations()` returns
  a handle resolved as `superseded` at the moment a replacing call advances the
  slot's generation, not when the abandoned request eventually completes.

## Disclosed choices

Judgement calls about how much hand-written machinery is realistic, recorded
here rather than buried.

1. **Rendering is explicit.** swift-state-graph's derivation and invalidation
   are the library's and are what is measured. Its observer _scheduling_ is not
   used, because `withGraphTracking` re-applies on the next event loop
   (`API-NOTES.md` probe `d2`) and this trace reads a settled value on the next
   line. All three non-Cog ports render explicitly at the close of a
   transaction; only Cog's reactions are the library's own. That is a scheduling
   mismatch, not a defect.
2. **The asynchronous layer is the port's.** 0.28.0 supplies no async node
   primitive, so request plans, generations, the acceptance rule, and the demand
   handles are hand-written, and their cost is inside every number this runtime
   reports.
3. **A plan carries a revision, not the products.** A Cog selector re-selects
   when any dependency is invalidated, including a fresh catalog under an
   unchanged request name. Reproducing that faithfully means a plan must change
   then too. It does so through a `catalogRevision` counter the port advances
   when it publishes a genuinely different catalog — one comparison per
   response — rather than by carrying `[Product]` into a value compared on every
   poll of every demanded slot.
4. **Generations live beside the graph, not in it.** A
   `Stored<AsyncCell<Value>>` holding value _and_ generation would invalidate
   every reader whenever a generation advanced, so an inventory burst that only
   made readings stale would re-render every row it touched. The graph holds the
   accepted value alone, exactly as Cog's value read sees it.
5. **The service is a constant, not a source.** Cog holds it in
   `_storefrontServiceCog`. `StorefrontService` is not `Equatable`, so a
   `Stored` for it would bind the ungated initializer this port forbids
   everywhere else, and it is installed once and never reassigned. The
   consequence is that the four rules reading the profile or the promotion
   fixtures read a constant here and a graph node in Cog — a small advantage to
   this port, stated rather than hidden.
6. **Demand is structural.** `pollAsyncDemand()` states in one place which slots
   a settlement polls: a row on screen or in the prefetch margin demands
   inventory and an offer because its badges read both; a cart line demands
   inventory because it reads availability, and an offer only when the profile's
   pricing ladder reaches the personalized-offer stage; an open product demands
   its detail payload and the recommendation shelf. That restates what the
   derivation graph already expresses, because the port owns the asynchronous
   layer and something has to decide which slots to poll.
7. **Release is a TTL sweep over per-product state.** Derived and asynchronous
   per-product nodes are dropped past grace when nothing demands them. Sources
   are kept — a favorite flag, a cart quantity, a variant, a recency rank, and
   an inventory generation are writes somebody made, and resetting them would be
   losing data rather than freeing a cache. The two funnel-wide keyed families,
   `searchScore` and `filterEligibility`, are kept too: the ranking reads one per
   candidate on every recomputation, so they are demanded for as long as the
   browse screen is held.
8. **`MainActor.assumeIsolated` at every rule boundary.** A `Computed` rule is
   `@Sendable`; this port is MainActor-confined. The assumption is checked on
   every rule invocation and that check is inside every measured number. It is
   the same pattern `StateGraphRuntimeComparisonGraph` already uses for PERF-10.

## The memoization hazard, and how this package answers it

`Computed` has two `rule:` initializers in the same type with the same argument
labels; only the `where Value: Equatable` one memoizes, and the library's doc
comment on it still describes the non-memoizing behavior. A `Value` that is not
`Equatable` binds the other one silently, compiles, produces correct answers,
and turns that branch of the graph into a recompute-on-read floor.

Every derived node in this port is built through `makeMemoizedComputed(_:_:)`
and every source through `makeSource(_:_:)`, both constrained
`Value: Equatable`, so the memoizing overloads are the only applicable ones and
the binding is decided in one place. `StorefrontStateGraphMemoizationTests`
refuses to take that on trust: it builds the probe's shape through those exact
constructors — an upstream that changes, a middle rule that maps the change to
an **equal** value, a leaf that counts its own runs — and then builds the same
shape again through an explicitly non-memoizing descriptor to prove the
instrument can tell the two apart.

## Running the tests

```sh
mise run test:storefront-state-graph
```

Never a bare filtered `swift test`: SwiftPM exits 0 when a filter selects
nothing. The wrapper enumerates the built tests first, requires every filter
alternative to match something, owns its own xUnit report, and refuses an
authoritative executed count of zero.

`mise run test:storefront-all` runs this suite together with the workload, Cog,
Observation, and agreement suites.

## Where its numbers are recorded

This port's cuts are `perf-16-storefront-state-graph-<cut>`. The recorded
numbers, the declared semantics as the agreement gate printed them, the
disclosed asymmetries above restated beside the timings, and what the
comparison does not establish are in
[`docs/swift/impl/perf.md`](../../../../../docs/swift/impl/perf.md#cross-runtime-results).
No `perf-16` cut is thresholded, so a change in this library moves a recorded
result and never fails Cog's CI.
