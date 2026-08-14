# Cog for Swift: data-oriented runtime

_August 6, 2026_

This document turns the semantics in [exploration.md](./exploration.md) into
an implementation plan. It does not settle value-reference, edge, hash-table, or
exclusivity layouts; benchmarks must choose those details.

The core idea: keep graph data in compact arrays owned by one MainActor
`Cogs`. This avoids locks, per-edge objects, weak references, and repeated
reference counting in the hot path.

This document serves Cog's third principle, minimizing runtime overhead. The
other three principles remain constraints: a faster layout does not win if it
weakens read correctness, fragments state, or pushes internal complexity into
normal app code.

## 1. Cost order

Optimize in this order:

1. **Run less user code.** Lazy reads and equality checks matter more than any
   storage trick. The core design already settles this.
2. **Make graph bookkeeping cheap.** Dirty flags, edge updates, and version
   checks should touch nearby integers, not scattered objects.

Current Swift systems often pay for locks, weak references, heap objects, or
`AnyKeyPath` hashing during graph work. Cog's MainActor rule removes the need
for these costs inside the graph. Appendix A records the source-level
evidence.

## 2. Shared lessons from other runtimes

Fast reactive systems now use the same broad algorithm:

- A write pushes flags, not computed values.
- A read pulls only the values it needs.
- Equal results stop downstream work.
- Dependency edges are reused between runs.
- Versions make “nothing changed” checks fast.

Cog combines a small state flag with versions: CLEAN, CHECK, and DIRTY decide
which states to visit; `changedAt` says whether a parent's value changed since
the last check; a global revision answers “has anything changed since turn N?”
for exports and debug tools.

Native runtimes add three warnings: common static state kinds may need special
fast paths; public value references must name data, not expose arena slots; and
multi-writer snapshots are wasted work in a single-threaded graph. Appendix B
keeps the detailed prior-art notes and measurements.

## 3. `Cogs` as a table of graph data

An entity-component-system (ECS) stores each kind of data in a separate
column. Cog uses the same pattern: states are rows, while flags, versions, and
edges live in parallel arrays — a structure of arrays, or SoA.

### 3.1 State storage

Each live state gets a dense `Int32` slot and a generation number. The context
owns parallel columns:

```swift
var flags:      ContiguousArray<StateFlags>
var changedAt:  ContiguousArray<UInt32>
var checkedAt:  ContiguousArray<UInt32>
var deps:       ContiguousArray<EdgeIndex>
var subs:       ContiguousArray<EdgeIndex>
var boundary:   ContiguousArray<Int32>
var generation: ContiguousArray<UInt16>
```

The push phase mostly reads `flags` and `subs`; separate columns keep those
bytes close in memory instead of loading whole state objects. The generation
number detects stale internal slot use after reuse.

### 3.2 Typed value columns

Values have different Swift types, so they cannot share one raw value array.
Each descriptor owns a typed column inside the app context (or the one
isolated context of a test or preview runtime):

```swift
final class Column<Value> {
    var values:  ContiguousArray<Value?>
    var pending: ContiguousArray<Value?>
    let equals: (Value, Value) -> Bool
}
```

This keeps value reads concrete, avoiding `Any` boxing and protocol dispatch
per read. A descriptor reaches its known column type through a checked setup
path and an internal downcast. A keyed box also stores typed keys in its
column, so selectors do not reopen erased keys during normal computation.

Manual, derived, and async states share topology; their descriptors differ in
how they produce a row. One keyed box stores one compute closure, not one
closure per key.

### 3.3 Edge layout remains open

One candidate translates alien-signals' link object into a 24-byte indexed
pool entry:

```swift
struct Edge {
    var dep, sub: Int32
    var prevSub, nextSub: EdgeIndex
    var nextDep: EdgeIndex
    var version: UInt32
}
```

One edge belongs to the producer's subscriber list and the consumer's
dependency list. Indices avoid ARC and weak loads, a free list recycles
removed edges, and a cursor can reuse edges when a selector reads the same
dependencies in the same order — zero steady-state allocation and hashing.

This is only a candidate. Benchmarks must compare:

- the shared linked edge pool;
- per-state arrays with prefix reuse, as in Reactively;
- small inline dependency storage with overflow, based on Incremental's
  common-case layout.

Alien-signals is strongest on mostly static graphs; Reactively performs well
when dependencies change often. Cog must measure both.

### 3.4 Propagation

The push phase walks subscriber edges and changes state flags, stopping when a
branch is already marked. Reactions go into a reused flat queue.

The pull phase walks dependencies and exits early when versions prove that no
parent changed. If a selector runs, Cog compares its new value with the old
one; an equal result keeps the old `changedAt`, so children do not recheck.

Use a reused explicit stack instead of recursion; deep chains are a benchmark
case. The same stack supplies cycle diagnostics: mark a state as computing on
entry, clear it on every exit path, and fail when a read reaches a computing
state. Format names and keys only on this rare error path.

## 4. Value-reference layout and hashing stay benchmark-gated

A public value reference names a descriptor and key. It never stores a state slot. Its
exact memory layout is open.

The correctness build uses inline `AnyHashable?`. This is several machine
words on current 64-bit Swift, so it is not a two-word value reference. Keep the public
struct resilient and do not mark it `@frozen`.

Even this simple value reference can avoid most hashing:

- During recomputation, first compare the next existing edge. If descriptor
  and key match the next read, follow its `Int32` slot directly.
- Only a first lookup or changed dependency set needs a dictionary.
- Each keyed descriptor owns `Dictionary<Key, Int32>`, so the cold lookup
  hashes the concrete key type rather than `AnyHashable`.
- A keyless descriptor caches its one slot per runtime context.

The benchmark compares the whole cost of three designs:

1. **Inline `AnyHashable`:** simple and allocation-free to create, but large
   and existential on cursor mismatches.
2. **Interned key token:** a two-word descriptor and token, but first use
   needs allocation, interning, and a token-retention rule.
3. **Generic keyed value reference:** fully specialized key storage, but adds the key type
   to the public read surface.

Keyed diamonds and key churn must decide. Hash caching, token interning, and a
custom identity table remain possible follow-ups only if profiles support
them. Swift's normal dictionary is already contiguous and specialized for a
concrete key.

## 5. ARC, dispatch, and exclusivity rules

Keep these rules until a benchmark disproves them:

- **Use integers in graph walks.** Retains, releases, and weak loads stay out
  of propagation. The app registry retains descriptors once. Use `Unmanaged`
  only where an internal pointer is unavoidable.
- **Store closures per descriptor.** A keyed box's rows share one closure.
- **Keep protocol existentials at the API shell.** Kind bits and
  per-descriptor functions handle inner dispatch.
- **Hoist buffer checks.** A phase may borrow slab storage with
  `withUnsafeMutableBufferPointer`, paying uniqueness and exclusivity checks
  once. Use `@exclusivity(unchecked)` only if release profiles show a real
  cost.
- **Respect package boundaries.** Measured accessors may need narrow
  `@inlinable` and `@usableFromInline` paths. Do not freeze value-reference layout just to
  gain early specialization.
- **Use new fixed storage where it helps.** `InlineArray` may hold small
  dependency caches or the first stack entries. `Span` can expose borrowed
  slab views to tests and debug tools without public pointers.

Internal registration handles and mechanism scopes remain final-class
values. Copies must share one idempotent cancellation resource; none of
these handles is public API (§6.2–§6.3).

## 6. Create Observation boundaries only when needed

Interior states never need `ObservationRegistrar`, which adds locking and
key-path lookup even with no watching view. Create one boundary object only on
the first UI read of a descriptor and key; the `boundary` column uses `-1`
until then. A graph with 1,000 states but 12 UI-read values owns 12 registrars.

The boundary object can expose one fixed phantom key path. After the graph
settles a turn, call `withMutation` only if that boundary value changed.
SwiftUI does not report exact subscription removal, so the boundary and state
stay pinned to the app context in v1. An optional view lease may come later if
measurement shows that old keyed states or notices are costly.

## 7. Arena lifetime must not leak into value references

leptos once exposed copyable arena-slot handles. Data could outlive the scope
that owned its slot, causing leaks and stale handles. Cog avoids that design:

- A value reference is a stable name: descriptor plus key. If a derived state is released,
  the same value reference can later create a fresh slot.
- ARC owns descriptors. The app context arena owns state rows.
- Manual and UI-boundary states live for the app context by default.
- Only `.whileObserved` rows use graph subscriber and explicit lease counts.
  `.cache` rows use cache limits and retention time.

Releasing a sync-derived row drops its value, returns edges to the free list,
and increases the slot generation. Releasing an async row first cancels its
task and increases the async generation, so late results fail before they can
touch a reused slot. Debug builds also check stale internal slot access.

## 8. Turns over the arrays

Core §3.2's turn model — the accumulating phase, then the six-step flush
order — maps to the storage plan in four passes:

1. **Accumulate:** writer subscripts update the pending value column and add
   each slot to a reused touched list. Reading through the writer sees staged
   values, so `c[countCog] += 1` works. Every access checks the turn ID.
2. **Commit sources (flush steps 1–2):** compare pending with current, keep
   real changes, increase `changedAt`, and push flags. Do not run selectors.
3. **Settle hot roots (flush step 3):** pull UI-boundary rows, active exports,
   and current reaction dependencies. Keep cold branches dirty.
4. **Notify and react (flush steps 4–6):** notify changed boundaries, offer
   values to each subscriber buffer, then run the reaction queue in
   registration order. Reaction writes become later FIFO turns.

In debug builds, store a fixed-size ring of integer records: turn ID, op-name
index, and touched slots. Resolve descriptor labels only when displaying the
history. Release builds should pay no debug-history cost.

## 9. Measurement plan

This plan amends §11 of the core document:

1. **Build the simple version first.** Use class states, edge arrays, and
   inline `AnyHashable` value references. Its test suite must cover escaped writers, self
   and multi-state cycles, dynamic cycles, equality-gated UI values, reaction
   write-back, manual lifetime, async generation safety, slow exports, guarded
   production-context installation, and scene recreation.
2. **Port `js-reactivity-benchmark`.** Include Kairo diamond, deep, broad, and
   unstable cases; dynamicBench sweeps; the Cellx lattice; keyed diamonds; and
   key churn. Keep the expected-run-count checks, since timing alone can hide
   duplicate work. Compare all three value-reference layouts.
3. **Build the data-oriented core behind the same tests.** Compare it with the
   simple build, swift-state-graph, and raw `@Observable`.
4. **Measure more than time.** Track steady-turn allocations (target zero),
   `box[key]` value-reference creation allocations (target zero), retain and release
   traffic in propagation (target zero), peak memory for 1,000-state graphs,
   registrar counts, and notices for pinned keyed states.
5. **Tune only from evidence.** Compare edge layouts, then consider unchecked
   exclusivity or custom hash tables only when a profile points there.

Prepare measured accessors so they can become inlinable without exposing all
storage. Do not mark value references `@frozen` before the layout result. Reserve reusable
buffer capacity from known descriptor counts to keep growth noise out of
benchmarks.

## 10. Deliberate non-goals

- **No MVCC or snapshot record lists.** They solve multi-writer isolation,
  which a MainActor graph does not have.
- **No height-based eager recompute queue.** Lazy pull does not need state
  heights. Revisit only if an eager batch mode becomes a requirement.
- **No locks or atomics in the graph.** Async generation checks live at the
  concurrency boundary, not in graph storage.
- **No unmeasured representation choice.** Value-reference layout, edge layout, hash
  tables, and exclusivity attributes wait for benchmarks.

## Appendix A: costs in current Swift designs

Source inspection found these costs:

- **swift-state-graph:** each state is a generic class with an
  `NSRecursiveLock`. Each edge is a separate class with two weak references
  and its own unfair lock. Tracked reads use
  `Thread.current.threadDictionary`. Propagation therefore walks objects,
  locks, and weak side tables.
- **Observation:** `withMutation` takes an unfair lock and probes an
  `[AnyKeyPath: Set<Int>]` dictionary twice, even with no observers. Tracked
  reads hash `AnyKeyPath` values. swift-sharing has reduced `withMutation`
  calls to lower this contention.

Cog's single-executor arena can remove those costs from interior states: no
locks, weak edges, per-edge allocation, key-path identity, or thread
dictionary. This remains a hypothesis to measure, not a benchmark result.

## Appendix B: detailed prior-art lessons

**JavaScript signal runtimes:** alien-signals and preact put one link in both
the producer and consumer lists. A cursor reuses links across similar runs, so
steady recomputation allocates and hashes nothing. They pack flags, reuse an
effect queue, and split pending from current values. Vue 3.6 reported about
13% lower memory, 1.2–3.6× gains on common paths, and up to about 30× on some
pull-heavy cases after adopting this core. Reactively's array prefix matching
can win when dependencies change often.

**Jane Street Incremental:** stores compact mutable state records, inlines the
first parent, and uses overflow storage for more. Its retrospective argues for
special static state kinds and concrete layouts instead of records of closures;
it reported about 30 ns to fire one state and a 3× real-app gain from concrete
layouts.

**leptos:** moved its primitive away from arena-owned copyable handles after
scope lifetime and data lifetime diverged. Cog keeps value references as names so slots
may come and go safely.

**salsa:** uses revision counters, `changed_at` and `verified_at`, and
backdating when recomputation returns an equal value. It can also skip whole
durability tiers and does not keep reverse edges. Cog takes the version and
backdating ideas, not the no-reverse-edge design.

**Glimmer:** shows the low-cost version-check floor with a global revision and
one `lastChanged` value per cell.

**Compose snapshots:** use MVCC record chains for multiple writers. Cog keeps
its read-observer framing and configurable equality, but not its storage.

## Appendix C: reading list

JavaScript:
[alien-signals](https://github.com/stackblitz/alien-signals) ·
[system.ts](https://github.com/stackblitz/alien-signals/blob/master/src/system.ts) ·
[Reactively](https://github.com/milomg/reactively/blob/main/Reactive-algorithms.md) ·
[preact Signal Boosting](https://preactjs.com/blog/signal-boosting/) ·
[Vue 3.6 port](https://github.com/vuejs/core/pull/12349) ·
[Solid signal source](https://github.com/solidjs/solid/blob/main/packages/solid/src/reactive/signal.ts) ·
[js-reactivity-benchmark](https://github.com/milomg/js-reactivity-benchmark) ·
[Super-charging fine-grained reactivity](https://dev.to/modderme123/super-charging-fine-grained-reactive-performance-47ph)

Native runtimes:
[leptos reactive_graph](https://docs.rs/reactive_graph/latest/reactive_graph/) ·
[leptos architecture](https://github.com/leptos-rs/leptos/blob/main/ARCHITECTURE.md) ·
[Sycamore reactivity v3](https://github.com/sycamore-rs/sycamore/pull/612) ·
[salsa](https://salsa-rs.github.io/salsa/) ·
[Incremental source](https://github.com/janestreet/incremental/blob/master/src/types.ml) ·
[Introducing Incremental](https://blog.janestreet.com/introducing-incremental/) ·
[Seven Implementations of Incremental](https://www.janestreet.com/tech-talks/seven-implementations-of-incremental/) ·
[Adapton](https://docs.rs/adapton/latest/adapton/) ·
[Compose snapshots](https://blog.zachklipp.com/introduction-to-the-compose-snapshot-system/) ·
[Glimmer validators](https://github.com/glimmerjs/glimmer-vm/blob/main/guides/05-validators.md)

Swift mechanics:
[swift-state-graph](https://github.com/VergeGroup/swift-state-graph) ·
[Observation source](https://github.com/swiftlang/swift/tree/main/stdlib/public/Observation) ·
[Swift optimization tips](https://github.com/swiftlang/swift/blob/main/docs/OptimizationTips.rst) ·
[Understanding Swift Performance](https://developer.apple.com/videos/play/wwdc2016/416/) ·
[Swift exclusivity](https://www.swift.org/blog/swift-5-exclusivity/) ·
[SE-0453 InlineArray](https://github.com/apple/swift-evolution/blob/main/proposals/0453-vector.md) ·
[SE-0447 Span](https://github.com/apple/swift-evolution/blob/main/proposals/0447-span-access-shared-contiguous-storage.md) ·
[HashTable.swift](https://github.com/apple/swift/blob/main/stdlib/public/core/HashTable.swift) ·
[operation costs](https://www.mikeash.com/pyblog/friday-qa-2016-04-15-performance-comparisons-of-common-operations-2016-edition.html) ·
[swift-collections](https://github.com/apple/swift-collections) ·
[ECS FAQ](https://github.com/SanderMertens/ecs-faq)
