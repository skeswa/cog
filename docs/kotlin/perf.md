# Cog for Kotlin: performance model

_Authored August 6, 2026._

The [shared state model](../design.md) owns the cross-platform rule that work
avoidance comes before representation tricks. This document owns the Android
cost model and the measurements that will choose its runtime.

Correct reads come first. The public API comes second. Data layout comes third.
An internal win is not a win if it weakens correctness, the public API, or the
singular graph.
Splitting features across stores is not a valid optimization; it would
fragment authoritative state.

## 1. Cost order

Optimize in this order:

1. do not recompute a state that cannot change;
2. do not recompose UI that did not read a changed value;
3. do not keep dead keyed states or jobs;
4. avoid allocation in a steady turn;
5. improve tables and edge layout;
6. specialize primitive storage only if measurements justify the API weight.

The first three usually beat a clever hash table.

```mermaid
flowchart LR
    W["source write"] --> D{"automatic output<br/>changed?"}
    D -->|no| Stop["stop"]
    D -->|yes| H{"live reader?"}
    H -->|no| Lazy["leave lazy"]
    H -->|yes| U["settle root"]
    U --> E{"root output<br/>changed?"}
    E -->|no| Stop
    E -->|yes| UI["recompose exact<br/>Compose scope"]
```

The target is zero heap allocation for an ordinary steady turn after warm-up.
That target is a benchmark gate, not a claim.

## 2. Platform advantages to keep

The Compose runtime already invests in:

- snapshot records and atomic apply;
- read observation;
- cached automatic state;
- mutation policies;
- primitive snapshot state;
- low-allocation internal collections;
- compiler-driven skipping.

Cog should not copy this machinery without proof that its public APIs are too
costly or cannot meet turn semantics.

The snapshot-backed prototype must use:

- direct `State.value` reads in the smallest useful Compose scope;
- explicit structural equality for every automatic state;
- one mutable snapshot per outer turn;
- one observer per store or effect group, not per state;
- stable descriptor objects;
- descriptor-and-key reads without a temporary handle.

## 3. Work avoidance

### 3.1 Dynamic edges

Capture only dependencies read on the current run. Remove old edges. When a
branch changes, stale sources must stop dirtying the state.

Measure both branch switching and steady branches. A design that rebuilds a
large edge set every read may lose even when it saves later work.

### 3.2 Equality gates

Use Kotlin `==` by default. Pass
`structuralEqualityPolicy()` to `derivedStateOf`.

The policy argument matters. An automatic state without one may invalidate readers
whenever a dependency changes, even when its result stays equal.

Android's own guidance calls `derivedStateOf` expensive. Cog uses it for
real shared automatic computation, not simple string joining. The spike must still measure
its cost across a large graph.

Equality itself can be costly for large values. Prefer small immutable values,
stable ids, or a domain equality policy with clear meaning. Do not use
referential equality just to hide in-place mutation.

### 3.3 Lazy and hot work

Cold automatic states compute on read. Hot roots settle after a turn so
reactions and UI have ready, equality-gated values.

The prototype must compare:

- settle every live root after each turn;
- let Compose pull UI-only roots during recomposition;
- a hybrid: eagerly settle reactions, leave UI-only roots lazy.

The hybrid may do less work. It may also make debug timing harder. Measure it.

### 3.4 Read close to use

Compose can skip only when state is read in a scope it can restart. Do not read
a whole screen model at the route if one leaf needs one count.

For very hot visual state, pass a lambda and read in layout or draw when the
Compose API supports it. This can skip composition. Use it only after a trace
shows composition is the cost.

## 4. Storage candidates

### 4.1 Sources and automatic values

First candidate:

| State data      | Candidate                      |
| --------------- | ------------------------------ |
| source value    | private `MutableState<T>`      |
| automatic value | `derivedStateOf(policy)`       |
| reaction reads  | shared `SnapshotStateObserver` |
| Cog metadata    | store-owned flat table         |
| UI boundary     | the same state `State<T>`      |

This gives one value cell rather than a Cog value plus a copied UI value.

Second candidate, only if needed:

- a custom push-pull Cog graph;
- one Compose `MutableState` version token per live UI root;
- direct Cog value reads after the token read.

The second shape controls graph layout but duplicates more logic. Correctness
tests must be identical for both.

### 4.2 State and key tables

Candidates for descriptor and box lookup:

- Kotlin `HashMap`;
- AndroidX `MutableScatterMap`;
- an integer state id stored on an installed descriptor;
- a two-level table: descriptor id, then box key.

AndroidX scatter maps use flat arrays and avoid a separate entry object for
each insertion. That is promising, not settled. Library availability, code
size, key quality, and small-map speed also matter.

Production has one store, but tests and previews still create isolated stores.
Never put a store-specific state id directly on a shared descriptor unless that
mapping supports those isolated stores safely.

### 4.3 Edges

Cog may need coarse dependency edges for leases and debug data even while
Compose owns correctness edges.

Candidates:

- a small mutable set per state;
- packed integer arrays with tombstones;
- a shared edge arena;
- store only live-root paths and rebuild on automatic runs.

Measure dynamic churn, not only a fixed diamond. Any arena must reclaim edges
when keyed states die.

### 4.4 Primitive values

Compose provides primitive snapshot state such as `MutableIntState` to
avoid boxing on primitive access. A generic `Cog<T>` may still box values
in Cog metadata or erased callbacks.

Possible specializations are `IntCog`, `LongCog`, `FloatCog`,
and `DoubleCog`. Do not add them until a realistic benchmark shows a
material end-to-end gain.

### 4.5 Key handles

The primary path is:

```kotlin
cogs[weather, zip]
```

It should not allocate a `Pair` or temporary value reference. Compare that with:

- `cogs[weather.at(zip)]`;
- an interned key handle;
- an `@JvmInline` handle;
- a cached state token remembered by Compose.

An inline class does not promise zero boxing in every generic or interface
call. Inspect bytecode and allocations.

## 5. Compose compiler and model stability

Strong skipping is on by default in current Kotlin Compose compiler releases.
It lets more composables skip, including ones with unstable parameters.

Still:

- model immutable data honestly;
- do not mutate public `var` fields behind Compose;
- prefer immutable collections when a collection crosses the UI boundary;
- use stable keys in lazy lists;
- check compiler stability reports before adding `@Stable`;
- treat `@Stable` and `@Immutable` as promises, not speed switches.

Wrong stability annotations can make UI stale. They are never a fix for a
mutable model.

## 6. Compose integration costs

Direct Cog reads should create no Flow collector and no coroutine. Each call
does need remembered lease ownership.

The prototype must count:

- recompositions;
- skipped recompositions;
- state `State` reads;
- leases created and released;
- allocations on first composition and steady recomposition;
- time to enter and leave a large lazy list;
- retained keyed states after list items leave.

Use stable lazy-list item keys. A box key should normally match the item's
domain id.

Do not wrap a direct Cog in `collectAsStateWithLifecycle`. That adds a
Flow, a collector job, and another Compose state cell around a value that is
already snapshot state.

## 7. Async and lifetime costs

Async churn can hide stale jobs and retained keys.

Measure:

- fast input changes under each scheduling policy;
- work that ignores cancellation;
- streams with fast equal and unequal emissions;
- grace-period cancel and restart;
- 1,000 keyed async states entering and leaving observation;
- process of clearing completed state cache entries.

Every async launch allocates a Job. The goal is not “no allocation” there. The
goal is no needless launch, collector, or retained job.

## 8. What to measure

Use layers:

```mermaid
flowchart TB
    Pure["JVM correctness tests<br/>compute counts and graph shape"]
    Micro["AndroidX Microbenchmark<br/>time and allocation"]
    Macro["Macrobenchmark<br/>frames, startup, scroll"]
    Trace["Perfetto and Compose tooling<br/>find why"]
    Pure --> Micro --> Macro --> Trace
```

Run Android benchmarks on physical devices in a release-like build. Debug
numbers are not release numbers. Pin inputs, warm-up rules, and library
versions in every result.

Key metrics:

- nanoseconds per turn at several graph sizes;
- allocations per steady turn;
- automatic compute count;
- dirty states visited;
- UI recomposition and skip count;
- frame timing and jank;
- memory after 1,000 and 10,000 keyed states;
- state and edge count after leases close;
- cold start and first-read cost;
- APK or AAR size change.

One number is not enough. Report median and tail values and keep raw benchmark
output.

<a id="9-spike-and-benchmark-plan"></a>

## 9. Spike and benchmark plan

### 9.1 Correctness corpus

The same tests run against the snapshot-backed and custom-graph candidates:

- chain, diamond, broad fan-out, and broad fan-in;
- dynamic branch switch;
- equal automatic result after unequal source writes;
- nested turn;
- staged writer read;
- escaped writer use after its turn closes;
- failed turn;
- read and write cycle;
- reaction order and reaction write-back;
- key collision and mutable-key misuse;
- lease loss and cache expiry;
- async cancel, stale completion, failure, and stream replacement;
- wrong-lane access;
- second production-store installation;
- screen recreation without manual-state loss.

Assert values and exact compute counts.

### 9.2 Microbenchmarks

Port useful shapes from
[js-reactivity-benchmark](https://github.com/milomg/js-reactivity-benchmark):

- 10, 100, 1,000, and 10,000 state chains;
- diamond and layered diamonds;
- one source with many readers;
- many sources with one sum;
- dependency switching;
- keyed create/read/release churn;
- one turn with 1, 10, and 100 writes;
- equal-output propagation;
- Compose lease enter/leave.

Compare:

1. Cog on Compose snapshots;
2. raw `MutableState` plus `derivedStateOf`;
3. the custom Cog graph candidate;
4. `MutableStateFlow` with `combine` and collection;
5. Molecule for whole-model cases where that comparison is fair.

Do not tune only to win a synthetic case.

### 9.3 UI benchmarks

Build three small apps:

- a settings form with independent fields;
- a feed with keyed rows and counters;
- a live dashboard with dynamic branches and fast updates.

Use Macrobenchmark and Perfetto for startup, scroll, updates, and navigation
away. Add a baseline profile only after measuring the unprofiled build. Keep
both results.

### 9.4 Gates

The first prototype passes only if:

- every correctness test passes;
- direct UI reads recompose no wider than raw Compose state;
- a steady one-source turn does not allocate after warm-up, or the remaining
  allocation is understood and accepted;
- keyed states and jobs return near baseline after lease expiry;
- no compared common graph shape has an unexplained order-of-magnitude loss;
- tracing can name the states and turn behind a slow update.

These are design gates. Exact numeric budgets should be set on the reference
devices after the first run.

### 9.5 Decisions unlocked by data

Benchmarks decide:

- snapshot-backed graph or custom graph;
- HashMap or scatter table;
- edge representation;
- key-handle representation;
- primitive-specialized APIs;
- eager, lazy, or hybrid hot-root settling;
- grace-period defaults;
- history and tracing level in release builds.

Until then, all remain candidates.

## 10. Deliberate non-goals

- beating raw `MutableState` on a single value;
- making every value observable across threads;
- hiding mutable collections behind stability annotations;
- replacing Room, DataStore, Flow, or WorkManager;
- optimizing debug history before release behavior;
- promising zero allocation for async work or first composition;
- a benchmark result without source, device, mode, and versions.

## Appendix A: measurement tools

- [Microbenchmark overview](https://developer.android.com/topic/performance/benchmarking/microbenchmark-overview)
- [Macrobenchmark overview](https://developer.android.com/topic/performance/benchmarking/macrobenchmark-overview)
- [Baseline Profiles](https://developer.android.com/topic/performance/baselineprofiles/overview)
- [Compose performance](https://developer.android.com/develop/ui/compose/performance)
- [Compose performance best practices](https://developer.android.com/develop/ui/compose/performance/bestpractices)
- [Compose `derivedStateOf` guidance](https://developer.android.com/develop/ui/compose/side-effects#derivedStateOf)
- [Diagnose stability](https://developer.android.com/develop/ui/compose/performance/stability/diagnose)
- [Compose tooling and recomposition counts](https://developer.android.com/develop/ui/compose/tooling/debug)

## Appendix B: runtime sources and prior art

- [Compose `DerivedState` source](https://android.googlesource.com/platform/frameworks/support/+/androidx-main/compose/runtime/runtime/src/commonMain/kotlin/androidx/compose/runtime/DerivedState.kt)
- [Compose `SnapshotStateObserver` source](https://android.googlesource.com/platform/frameworks/support/+/androidx-main/compose/runtime/runtime/src/commonMain/kotlin/androidx/compose/runtime/snapshots/SnapshotStateObserver.kt)
- [Compose `SnapshotStateMap` source](https://android.googlesource.com/platform/frameworks/support/+/795cb9ba01d8d529758d00d225615880bce6149d/compose/runtime/runtime/src/commonMain/kotlin/androidx/compose/runtime/snapshots/SnapshotStateMap.kt)
- [AndroidX `MutableScatterMap`](https://developer.android.com/reference/androidx/collection/MutableScatterMap)
- [Compose primitive state](https://developer.android.com/reference/kotlin/androidx/compose/runtime/MutableIntState)
- [Strong skipping](https://developer.android.com/develop/ui/compose/performance/stability/strongskipping)
- [Molecule](https://github.com/cashapp/molecule)
- [Reactively algorithm notes](https://github.com/milomg/reactively/blob/main/Reactive-algorithms.md)
- [alien-signals](https://github.com/stackblitz/alien-signals)

Reading source helps form candidates. Only Cog's own tests and measurements can
settle its layout.
