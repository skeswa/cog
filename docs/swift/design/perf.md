# Cog for Swift: data-oriented runtime

_August 6, 2026_

This document turns the semantics in [exploration.md](./exploration.md) into
an implementation plan. The comparisons in §9.6 select inline `AnyHashable`
value references and the shared linked edge pool within the arena candidate,
but retain the simple core as the shipping implementation. Hash-table and
exclusivity layouts remain benchmark-gated.

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

### 3.3 Shared linked edge pool

Cog translates alien-signals' link object into a 24-byte indexed pool entry:

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

The M6 comparison measured:

- the shared linked edge pool;
- per-state arrays with prefix reuse, as in Reactively;
- small inline dependency storage with overflow, based on Incremental's
  common-case layout.

The shared pool won the expected mostly-static shape on instructions. The
prefix candidate won high churn on instructions, but not wall time, while
adding per-turn ARC. The inline-plus-overflow candidate won neither shape.
§9.6 records the complete comparison and selection. Both losing candidates
remain behind test-and-benchmark selectors so the decision stays reproducible.

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

## 4. Inline value references are selected; hashing stays benchmark-gated

A public value reference names a descriptor and key. It never stores a state
slot. The v1 layout carries the key inline as `AnyHashable?`; the public struct
remains resilient rather than `@frozen`.

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

The keyed-diamond and churn comparison in §9.6 selects **inline
`AnyHashable`**. Interning narrowed a reference and saved about 2% of executed
instructions, but did not improve both wall-time workloads: churn regressed 4%
and still paid an unbounded process-wide table plus a lock on every reference
construction. The generic candidate was 6% slower on the keyed diamond and
required a permanent keyed overload surface. Neither displaced the simple
layout that already creates references with zero allocations.

Hash caching and descriptor-local `Dictionary<Key, Int32>` lookup remain
possible follow-ups if M6 profiles support them. They can hash the concrete key
on a cold lookup without changing the selected public representation.

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

### 9.6 Recorded results

Numbers, and only numbers that were actually taken. Each entry names the task
that recorded it and the environment it came from; a threshold with no
measurement behind it is a guess that fails at the worst moment.

**Allocation, simple core** — `M5-06`, 2026-08-17, `mactop` (Apple Silicon,
12 cores), Xcode 26.4 / Swift 6.3.0, release, harness 1.36.2 with the malloc
interposer. Scaled per operation, and byte-identical from p0 to p100 across
1,300+ samples, so these are exact costs rather than distributions.

| Operation                                 | `mallocCountTotal` | `objectAllocCount` | Scenario                  |
| ----------------------------------------- | ------------------ | ------------------ | ------------------------- |
| `box[key]` value-reference creation       | **0**              | **0**              | PERF-06, green as written |
| Steady turn (one write, one tracked read) | **7**              | **7**              | PERF-01, ceiling recorded |

The steady turn does not reach zero on the simple core, which is the expected
state of the class-state build rather than a defect: §9.1 builds it from class
states and edge arrays, and §5's no-ARC, no-existential rules are what the
data-oriented core adopts in M6. PERF-01 is therefore pinned against _drift_
rather than against zero — `mise run bench:baseline:check` fails if a steady
turn's allocation count moves from the recorded baseline by more than 100 raw
allocations, where one extra allocation per turn is 1,000 (`M5-11` explains the
units and the noise floor). The cost cannot creep upward unnoticed while M6 is
being built. Zero remains the replacement target; the M6 candidate reaches five
rather than zero, so `M6-12a` retains the simple core and its drift gate instead
of pretending the target was met.

Attribution, from the same session, so M6 knows where to look:

| Path                                                      | Cost       | Note                                                                                                   |
| --------------------------------------------------------- | ---------- | ------------------------------------------------------------------------------------------------------ |
| `peek` of a manual source, 10,000×                        | ~0 total   | source lifetime is `.app`; nothing is scheduled                                                        |
| `box[key]` creation, 10,000×                              | 0 total    | naming a state reaches no state                                                                        |
| Tracked read `cogs[derivedCog]` of a clean value, 10,000× | ~12 total  | a settled read is effectively free                                                                     |
| **`peek` of a clean derived value, 10,000×**              | **6 each** | transient demand renews `whileObserved` grace on every call — a sleeper per peek, not settle-walk cost |
| Commit with no read                                       | 6 each     | the turn machinery itself                                                                              |
| Commit plus a tracked read                                | 7 each     | PERF-01                                                                                                |

The `peek` figure is worth keeping in view: it is lifetime machinery, not graph
work, and it is why PERF-01 measures the **tracked** read. A UI read is the
tracked one, and a UI read is what a steady turn serves.

**Propagation ARC traffic, simple core** — `M5-07a`, same session and
environment. Two fans over one source, differing only in how many consumers
hang off it, so subtracting one from the other attributes traffic to
propagation rather than to the commit boundary. Both deterministic at every
percentile.

| Shape                                | retains | releases | object allocs | mallocs |
| ------------------------------------ | ------- | -------- | ------------- | ------- |
| 1 consumer (`perf-01-steady-turn`)   | 65      | 92       | 7             | 7       |
| 16 consumers (`perf-02-propagation`) | 1,116   | 2,032    | 26            | 26      |
| **Marginal, per consumer**           | **≈70** | **≈129** | ≈1.3          | ≈1.3    |

So settling and reading one changed consumer costs about seventy retains and a
hundred and thirty releases. PERF-02 asks for none of it, and none of it is
what §5's "no ARC, locks, or existentials in graph walks" rule buys — in M6,
not here. The simple core walks class states held through existentials, and
every hop retains. Until the arena core lands, PERF-02 is pinned against drift
from these numbers, so the traffic cannot grow unnoticed. The arena candidate
cuts this traffic substantially but does not reach zero; `M6-12a` records why
that is not enough to replace the shipping core.

Worth noting for M6: releases outnumber retains roughly two to one. That is not
an imbalance — the extra releases are objects created before the measured
region and freed inside it — but it does mean a change that halves retains
without touching releases has moved less than half the traffic.

**Thousand-state footprint, simple core** — `M5-07b`, same session and
environment. Five hundred keyed sources and five hundred keyed consumers, built
and settled in a fresh context: a thousand states from two declarations, which
is how a screen actually reaches that number.

| Percentile | resident-memory growth per build |
| ---------- | -------------------------------- |
| p50        | 0.87–1.28 MB across five runs    |
| p100       | 1.28–1.56 MB across five runs    |

**About 1.4 MB for a thousand states — roughly 1.4 KB each.**

Stated as a range on purpose. This is the one metric in §9.6 that is _sampled_
rather than counted: resident memory is page-granular, and the delta only grows
on the iterations where the peak actually advances, so p0 reads zero on every
run once the allocator already holds the pages. The threshold is accordingly a
mebibyte of drift — about two and a half times the worst spread observed, wide
enough never to cry wolf and narrow enough that a graph grown to twice its
footprint fails.

**Lazy boundary objects** — `M5-07c`, same session and environment. Nine
hundred and eighty-eight keyed sources settled with `peek`, twelve keyed
consumers read through the tracked subscript: exactly a thousand states, and
exactly twelve values on screen.

| Metric                  | p0     | p100   | samples |
| ----------------------- | ------ | ------ | ------- |
| `observationBoundaries` | **12** | **12** | 2,160   |

Twelve, at every percentile, with a thousand states in the graph. PERF-04 as
worded, and the only figure in §9.6 that is already exactly what the scenario
asks for rather than a number to ratchet down.

The gate is exact-drift rather than a tolerance, because this is a count of
live objects rather than a sampled quantity: a core that started giving every
state a boundary would report 1,000 where the baseline says 12, and there is no
noise floor to leave room for. Verified in both directions — pointing the
tracked reads at all 988 sources fails immediately with
`Difference Δ 976` against `Threshold Δ 0`.

It is a _custom_ metric because no built-in one expresses it. `objectAllocCount`
counts allocations over a region, and what PERF-04 claims is about what
survives, not about what was made.

**Value-reference layout: baseline recorded, candidates pending** —
`M5-09a`, 2026-08-17. The layout choice now lives behind one internal type,
`CogKey`, selected at build time by `COG_TEST_VALUE_REFERENCE_LAYOUT` and
verified by an infrastructure test that compares what the environment asked for,
what the test target compiled, and what the _library_ compiled — the third
comparison being the one that matters, since the layout is a library setting
chosen by a test runner.

The recorded baseline candidate is **inline `AnyHashable`**, the correctness
core's layout: one existential box per reference, keys of three words or fewer
stored inline and larger ones allocating. Every number in §9.6 above was
measured under it, including PERF-06's zero-allocation `box[key]` creation, so
the interned-token and generic-keyed candidates have something exact to be
measured against rather than a remembered impression.

**Interned tokens: implemented, and already a third the size** — `M5-09b`,
2026-08-17. A key is carried as one `Int` and a process-wide table remembers
what it stands for.

| Layout               | `MemoryLayout<ManualCog<Int>>.size` |
| -------------------- | ----------------------------------- |
| inline `AnyHashable` | 48 bytes                            |
| interned token       | **17 bytes**                        |

A descriptor reference plus an inline `AnyHashable?` against a descriptor
reference plus an `Int?`. That is the size win this candidate was sent to find,
visible before any benchmark runs — and it is why the storage-shape
infrastructure test now follows the selected layout rather than pinning one
number for both.

Two costs the number does not show, and `M5-09e` has to weigh them:

- **The table never shrinks.** A screen that churns a thousand keys interns a
  thousand entries and keeps them for the life of the process. COUNT-08's churn
  shape is where that shows up.
- **Interning takes a lock.** Not in a graph walk — equality and hashing touch
  only the token, which is the point — but every `box[key]` pays it once, which
  is exactly what PERF-06 measures.

The complete behavior suite passes unchanged under both layouts, which is
COUNT-09's promise arriving early for this candidate.

**Value-reference comparison and selection** — `M5-09e`, 2026-08-17, `mactop`
(Apple Silicon, 12 cores, 24 GB), Darwin 25.4.0, Xcode 26.4 / Apple Swift
6.3.0, release, harness 1.36.2. All six runs used the same checkout and host
session. Each candidate was rebuilt through `COG_TEST_VALUE_REFERENCE_LAYOUT`;
each benchmark retained its shared scenario's exact run-count assertion.

The keyed diamond is 100 keys × 5 arms × 500 turns. Churn keeps a 10-key live
window across 500 turns and creates 510 keys. These are whole-scenario
benchmarks, so they report wall clock, instructions, and peak resident memory
only: each iteration releases a `Cogs`, and M5-11 forbids process-global malloc
or ARC counting when teardown work can finish after the measured region.

| Layout               | reference size | keyed diamond p50 |   key churn p50 | peak resident (diamond / churn) |
| -------------------- | -------------: | ----------------: | --------------: | ------------------------------: |
| inline `AnyHashable` |       48 bytes |   1,547 M / 78 ms | 1,536 M / 94 ms |                     121 / 15 MB |
| interned token       |       17 bytes |   1,506 M / 77 ms | 1,512 M / 98 ms |                     119 / 15 MB |
| generic keyed        |       16 bytes |   1,640 M / 83 ms | 1,540 M / 95 ms |                     121 / 15 MB |

The two workload cells are instructions / wall clock. Each percentile came
from 31–39 samples. Instruction counts were tight within a run; wall clock is
read as a workload-level direction rather than a future threshold.

**Selected: inline `AnyHashable`.** It is the only candidate with no new
structural cost, and it already satisfies PERF-06 at zero allocations per
`box[key]` construction. The interned candidate does execute 1.6–2.7% fewer
instructions and narrows the reference to 17 bytes, but the reduction does not
become a consistent wall-time win: keyed-diamond p50 improves by 1 ms while
churn regresses by 4 ms. Paying an unbounded process-wide key table and a lock
on every construction for that result would violate the cost order in §1.

The generic candidate is 16 bytes for the measured `Int` key but performs an
erasure adapter at the current heterogeneous core boundary. It ties inline on
churn and costs about 6% on both diamond instructions and wall time. More
importantly, its box-specific keyed reference types require a permanent public
overload surface across reads, writes, status, refresh, reactions, mechanisms,
projections, and testing. Perf §4's descriptor-local concrete-key dictionary
can capture the cold-lookup advantage without that public cost.

The selector and both losing candidates remain test-and-benchmark-only so
COUNT-09 can continue proving behavior parity and the recorded shapes remain
reproducible. Unset — every ordinary consumer build — selects inline.

**Edge-layout comparison and selection** — `M6-05c`, 2026-08-17, `mactop`
(Apple Silicon, 12 cores, 24 GB), Darwin 25.4.0, Xcode 26.4 / Apple Swift
6.3.0, release, harness 1.36.2, malloc interposer 1.4.0. All six runs used the
same checkout and host session. Each candidate was rebuilt through
`COG_TEST_CORE=arena` and `COG_TEST_EDGE`; the measured graph stayed alive and
quiescent across samples so the process-global malloc and ARC counters were
valid.

Both roots read one stable control and 32 data sources. The mostly-static
workload changes one value while retaining all 33 edges in the same order. The
high-churn workload replaces the 32-edge suffix every turn while retaining the
control edge.

| Layout               | mostly-static p50 |    high-churn p50 | mallocs / objects | static retains / releases | churn retains / releases |
| -------------------- | ----------------: | ----------------: | ----------------: | ------------------------: | -----------------------: |
| shared linked pool   | **294 K / 12 µs** |     335 K / 13 µs |             7 / 7 |                 233 / 256 |                228 / 251 |
| prefix arrays        |     303 K / 12 µs | **321 K / 13 µs** |             7 / 7 |                 233 / 256 |                229 / 252 |
| inline plus overflow |     304 K / 12 µs |     326 K / 13 µs |             7 / 7 |                 233 / 256 |                228 / 251 |

The workload cells are instructions / wall clock. The static and churn runs
produced 245–260 and 231–235 samples per candidate, respectively. Instruction
counts were exact through p90; p100 ranged from 313–331 K for static and
349–363 K for churn. Wall-clock distributions overlapped.

**Selected: shared linked edge pool.** Mostly-static dependency sets are the
ordinary graph shape, and the pool executes 3.1–3.4% fewer instructions there
without moving wall time or allocation counts. Prefix arrays execute 4.2%
fewer instructions than the pool under deliberately complete suffix churn,
but all candidates still report 13 µs at p50 and the prefix representation
adds one retain and one release per turn. That ARC is directly contrary to
§5's graph-walk rule, and the measured churn result does not justify a nested
array per state. Inline plus overflow is structurally more complex and wins
neither workload.

The shared pool is therefore the ordinary arena build. It keeps one compact
entry per edge, reconciles stable ordered reads in place, and recycles removed
entries through an index free list without per-edge ARC. Prefix and inline
remain test-and-benchmark-only so COUNT-09 and PERF-09 can reproduce the
comparison.

**Pinned-key notice traffic** — `M5-07d`, same session and environment. A keyed
family where the UI once read `n` rows and now writes and reads exactly one.
Every other row is pinned to the app context and untouched, so anything that
scales with `n` is a turn doing work it has no business doing.

| Pinned keys | retains/turn | releases/turn | mallocs/turn | wall clock/turn |
| ----------- | ------------ | ------------- | ------------ | --------------- |
| 1           | 68           | 95            | 7            | 2.7 µs          |
| 100         | 167          | 194           | 7            | 4.8 µs          |
| 500         | 567          | 594           | 7            | 14 µs           |

**Exactly one retain and one release per pinned key per turn**, and about 23 ns
of wall clock — linear across all three points, and identical at every
percentile. Allocations do not scale at all: seven per turn regardless, so
nothing is _allocated_ per pinned key.

So **a turn currently costs O(pinned keys), not O(changed keys)**. A screen that
has scrolled past ten thousand rows pays ten thousand retain and release pairs
on every write, for rows nobody is looking at. That is the cost PERF-07 exists
to bound; it is now bounded and pinned against drift, and it is a direct target
for M6, where §5's "no ARC, locks, or existentials in graph walks" and §7's
dirty-set propagation are the rules that turn it into O(changed). All three
points stay in the suite so M6 can show the slope going flat rather than merely
showing one number get smaller.

**Runtime comparison, before core selection** — `M6-11c`, 2026-08-17,
`mactop` (Apple Silicon arm64, 12 cores, 24 GB), macOS 26.4.1 / Darwin 25.4.0,
Xcode 26.4 (17E192) / Apple Swift 6.3.0, release, harness 1.36.2. The external
adapter is swift-state-graph 0.28.0 at
`e602fcdb19342a38c135543e7228b3fd60753dc7`; its transitive SwiftSyntax pin is
603.0.2. All sixteen exact-name runs used the same checkout and host session.
The simple and arena runs rebuilt Cog through `COG_TEST_CORE`; the arena used
the selected shared-pool edge layout, and both used inline `AnyHashable` value
references. StateGraph and raw Observation were captured in the simple-compiled
executable because neither adapter reaches Cog.

Every sample checked its final value and exact derived-body count before the
harness accepted the timing. The common shapes are the Kairo ports: a five-arm
diamond over 500 turns, a 50-link chain over 50 turns, fifty two-link broad
arms over 50 turns, and an unstable consumer with 20 repeated branch reads over
100 turns. The three memoized graphs cost 3,006, 2,550, 5,100, and 302 derived
runs respectively. Raw Observation has no derived cache: its first three counts
are the same, while unstable costs 2,121 ordinary computed reads. That
difference is an adapter result, not work hidden from the table.

| Runtime                |      diamond p50 |           deep p50 |        broad p50 |       unstable p50 |
| ---------------------- | ---------------: | -----------------: | ---------------: | -----------------: |
| simple Cog             |  99 M / 4.964 ms |    51 M / 2.540 ms |    239 M / 12 ms |    45 M / 2.484 ms |
| arena Cog              | 103 M / 4.362 ms |    68 M / 2.654 ms | 214 M / 8.905 ms |    31 M / 1.272 ms |
| swift-state-graph 0.28 |    506 M / 25 ms |      301 M / 14 ms |    715 M / 36 ms |   152 M / 7.479 ms |
| raw `@Observable`      |  16 M / 0.787 ms | 4.106 M / 0.205 ms |  45 M / 2.130 ms | 7.094 M / 0.327 ms |

Each workload cell is instructions / wall clock. Units preserve the harness's
displayed precision rather than inventing digits after a rounded millisecond.
The companion process-level measurements were:

| Runtime                | diamond memory / samples | deep memory / samples | broad memory / samples | unstable memory / samples |
| ---------------------- | -----------------------: | --------------------: | ---------------------: | ------------------------: |
| simple Cog             |              13 MB / 595 |         14 MB / 1,163 |            13 MB / 241 |             13 MB / 1,172 |
| arena Cog              |              13 MB / 684 |         14 MB / 1,122 |            14 MB / 336 |             13 MB / 2,328 |
| swift-state-graph 0.28 |              13 MB / 118 |           13 MB / 212 |             14 MB / 84 |               13 MB / 400 |
| raw `@Observable`      |            13 MB / 3,730 |        13 MB / 10,000 |          13 MB / 1,379 |             13 MB / 8,854 |

Memory is p50 peak resident memory for the complete benchmark process, not an
allocation attributed to one graph; at these sizes its 13–15 MB spread is not
a useful separator. Sample counts differ because every exact-name benchmark
ran to the same three-second duration cap.

Recorded without selecting a core: arena wall clock is lower than simple on
diamond, broad, and unstable and higher on deep; instructions are higher on
diamond and deep and lower on broad and unstable.
swift-state-graph is the slowest graph runtime in all four shapes. Raw
Observation is the lower bound and is fastest even where its uncached unstable
reads do seven times the derived work. `M6-11d` turns the recorded timing
distributions into generous gates, and `M6-12a` — not this measurement task —
weighs the mixed core result and selects the default.

**Absolute CI gates** — `M6-11d`, 2026-08-17. Wall-clock p90 is the only
PERF-10 metric promoted from comparison evidence to a regression promise.
Instructions remain explanatory and peak resident memory remains too coarse at
these workload sizes. Each ceiling is roughly three times the slower recorded
p90 for its runtime/workload cell. Cog uses the slower of simple and arena, so
the gate neither decides `M6-12a` nor needs rewriting after `M6-13` executes
that decision.

| Runtime           | Recorded p90: diamond / deep / broad / unstable | Absolute ceilings: diamond / deep / broad / unstable |
| ----------------- | ----------------------------------------------- | ---------------------------------------------------- |
| Cog, either core  | 5.231 / 2.750 / 13 / 2.755 ms                   | **20 / 10 / 40 / 10 ms**                             |
| raw `@Observable` | 0.820 / 0.216 / 2.277 / 0.350 ms                | **3 / 1 / 8 / 2 ms**                                 |
| swift-state-graph | 26 / 15 / 37 / 7.696 ms                         | **80 / 50 / 120 / 25 ms**                            |

The encoding is intentionally mechanical. Ordo One's static command compares
the measured p90 with a reference and then applies the benchmark's absolute
tolerance symmetrically; it exits nonzero for a large improvement as well as a
regression. Every committed `Thresholds/*.p90.json` reference is therefore
zero, and the positive tolerance in `RuntimeComparisonBenchmarks.swift` is the
actual one-sided ceiling. A nonnegative metric cannot cross the lower side, so
only exceeding the ceiling fails. The wrapper additionally verifies all twelve
PERF-10 files exist and still name registered benchmarks before invoking the
harness; upstream itself only fails when _none_ exist and could otherwise let
one file hide eleven missing gates.

PERF-06 stays exact in the same gate: static p90 references of zero for
`mallocCountTotal` and `objectAllocCount`, both with zero p90 tolerance. The
allocating witness runs first and must report nonzero, so this cannot pass by
silently measuring nothing. `mise run bench:thresholds:sentinel` supplies an
impossible temporary reference to a real Observation workload and succeeds only
when the same command reports a threshold regression. CI runs
`mise run bench:thresholds:check` in one globally serialized job on the pinned
bare-metal runner.

**Core decision** — `M6-12a`, 2026-08-17. **The simple core remains the
shipping default, and M6 does not recommend a 0.2.0 release.** The arena stays
behind `COG_TEST_CORE=arena` with the selected shared-pool edge layout as a
behavior-equivalent research and benchmark candidate.

Correctness is not the discriminator: the same 248 public behavior scenarios
pass under both implementations, and both preserve the public API and one-graph
ownership model. The runtime comparison is genuinely mixed. Arena p50 wall
clock improves diamond by 12%, broad by 26%, and unstable by 49%, while deep
regresses by 4%. Instructions regress by 4% on diamond and 33% on deep, then
improve by 10% on broad and 31% on unstable. That is promising for wider and
dynamic graphs, but it is not a general replacement result.

The cost targets decide the close call. The existing quiescent PERF-01,
PERF-02, and PERF-07 probes were rerun back-to-back under both selectors in the
same pinned session:

| Workload                | Core   | mallocs / objects | retains / releases | p50 wall clock |
| ----------------------- | ------ | ----------------: | -----------------: | -------------: |
| steady turn             | simple |             7 / 7 |            66 / 93 |       2.202 µs |
| steady turn             | arena  |             5 / 5 |            48 / 67 |       2.425 µs |
| 16-consumer propagation | simple |           26 / 26 |      1,132 / 2,048 |          40 µs |
| 16-consumer propagation | arena  |             5 / 5 |          424 / 488 |          21 µs |

Arena substantially reduces wide-propagation work, but it reaches neither
promised zero: a steady turn still allocates five times and propagation still
performs hundreds of retains and releases. The smallest steady turn is also
10% slower despite the lower counts.

The pinned-key result is more important because it tests algorithmic shape,
not a constant:

| Pinned keys | simple retains / releases / p50 | arena retains / releases / p50 |
| ----------: | ------------------------------: | -----------------------------: |
|           1 |              69 / 96 / 2.826 µs |             51 / 70 / 3.172 µs |
|         100 |            168 / 195 / 4.850 µs |           249 / 268 / 4.583 µs |
|         500 |               568 / 595 / 15 µs |          1,049 / 1,068 / 10 µs |

Simple pays exactly one retain and one release per additional pinned key;
arena pays exactly two of each. Arena's compact traversal wins wall clock at
larger sizes, but the M6 target was to make a turn O(changed keys) instead of
O(pinned keys), not to traverse every irrelevant row faster. The candidate
therefore steepens the explicit ARC slope it was built to flatten.

Replacing a mature, correct core is justified by a broad improvement or by
removing a structural cost that matters as graphs grow. Arena does neither yet:
it wins important workloads, loses others, misses both zero-cost targets, and
preserves the pinned-key scaling defect at twice the ARC slope. Shipping that
trade would add representation risk without fulfilling the reason for the
swap. Reconsider only after a candidate makes pinned-key work O(changed), then
remeasure steady, deep, broad, and unstable shapes without a new common-path
regression. Since 0.2.0 was scoped to the core replacement, the principled
release recommendation is no release rather than a version containing no
shipping change.

**M6 closeout** — `M6-12b`, 2026-08-17. The no-release record is approved.
The decision is implemented, not merely proposed: an unset selector compiles
the simple core, and the complete 248-scenario behavior suite still passes
under both explicit core selections. The committed performance gate verifies
all 13 registered threshold workloads, proves malloc counting is live, keeps
PERF-06 exactly allocation-free at p90, and bounds every PERF-10 runtime cell.
The edge and runtime measurements, decision rationale, and retained selector
are therefore reproducible without changing what an ordinary consumer builds.

There is no 0.2.0 payload. The only change that version was chartered to ship
was arena replacing simple, and the measurements rejected that replacement.
Changing a changelog, version reference, tag, DocC deployment, exact-version
consumer, or GitHub Release would manufacture publication work for an
unchanged library. `M6-12c`, `M6-12d`, and `M6-12e` are consequently not
applicable; M6 closes on the recorded evidence above, and M7 may start from the
unchanged simple default.

Conditional publication disposition:

- **M6-12c — not applicable.** No `0.2.0` candidate was approved, so no
  annotated tag was created or pushed. The remote `refs/tags/0.2.0` remains
  absent.
- **M6-12d — not applicable.** With no tag, there is no tag-triggered DocC
  deployment and no exact `0.2.0` package version for a scratch consumer to
  resolve. Revision-based substitutes would not prove either post-release
  claim and are deliberately not reported as such.
- **M6-12e — not applicable.** There is no approved candidate, tag, or verified
  release artifact for a `0.2.0` GitHub Release to describe. No release was
  drafted or published; the conditional publication chain terminates here.

**Post-M6 call-site profile** — `M9-01`, 2026-08-18, `mactop` (Apple Silicon
arm64, 12 cores, 24 GB), macOS 26.4.1 / Darwin 25.4.0 (25E253), Xcode 26.4
(17E192) / Apple Swift 6.3 (swiftlang-6.3.0.123.5), release configuration with
debug info. This is the profile `M6-12a` said should precede any large
post-M6 investment, and the first §9.6 entry that attributes cost to **call
sites** rather than counting it at the boundary.

Measured outside the benchmark package, in a standalone one-executable harness,
because the question is where a turn's cost is incurred and the benchmark
harness cannot say. Allocations and ARC are attributed by a
`DYLD_INSERT_LIBRARIES` interposer over the malloc family and the Swift retain
and release entry points — including the bridge-object, unknown-object, and
Objective-C spellings, without which the pinned-key slope reads flat and the
measurement lies. Recording is armed for exactly one turn after two hundred
warm-up turns, so every count below is one turn's cost rather than an average.
Leaf time comes from `sample` at 1 ms over a six-second window. The harness and
its exact commands are recorded in
[`swift/Benchmarks/probes/M9-01-call-site-attribution.md`](../../../swift/Benchmarks/probes/M9-01-call-site-attribution.md).

The method reproduces every recorded count it overlaps: seven mallocs for a
simple-core steady turn (`M5-06`), five for the arena (`M6-11c`), and one retain
and one release per pinned key on simple against two on arena (`M5-07d`,
`M6-11c`). Allocation counts are taken with ARC recording disarmed, because
arming it costs one allocation of its own — a constant, and the reason the two
recording modes are separate.

**The seven steady-turn allocations, simple core, by call site.**

| Allocation | Call site                                              | What it is                                        |
| ---------- | ------------------------------------------------------ | ------------------------------------------------- |
| 1          | `CogOps.commit(_:to:name:)`, CogOps.swift:96           | escaping closure box for the write sugar          |
| 2          | `Cogs.commit(named:_:)`, Writer.swift:81               | escaping closure box `withTurn` receives          |
| 3          | `Cogs.startTurn(named:)`, CogTurn.swift:283            | the `CogTurnID` object                            |
| 4          | `Cogs.startTurn(named:)`, CogTurn.swift:283            | the `CogTurn` object                              |
| 5          | `CogTurn.touch(_:)`, CogTurn.swift:59                  | `touchedSources` regrown from empty               |
| 6          | `Cogs.invalidateSubscribers(of:)`, CogSettle.swift:279 | the invalidation list regrown from empty          |
| 7          | `DerivedCogState.run(in:)`, DerivedCogState.swift:219  | the dependency list, reallocated by copy-on-write |

**None of the seven is graph representation.** Four are turn machinery that
exists whichever core is compiled, and three are per-turn arrays that cannot
reuse their capacity: two are regrown from empty, and the dependency list
reallocates because `run(in:)` holds the previous list in `previousDependencies`
while clearing `dependencies`, so `keepingCapacity: true` cannot keep anything. That is why the arena reached five rather
than zero: the representation swap could only ever move the minority of this
list it owns. A commit with no read costs the same seven; a tracked read of a
clean value costs none, so all seven belong to the write.

**Where a steady turn's time goes, simple core.** Leaf attribution over 5,073
samples; 1.97 µs per turn (2,000,000 turns in 3.94 s, three runs within 1%).

| Bucket                                   |    Share |
| ---------------------------------------- | -------: |
| ARC retain and release                   |    23.5% |
| Generic metadata instantiation           |    19.0% |
| Actor-isolation checks                   |    12.4% |
| Exclusivity checks (`swift_beginAccess`) |     8.2% |
| **Cog's own compiled code**              | **6.1%** |
| malloc and free                          |     5.5% |
| Value-witness copies                     |     5.3% |
| Weak-reference loads                     |     5.1% |
| Dynamic casts and conformance lookup     |     4.2% |
| Unattributed runtime and long tail       |    10.8% |

**About six percent of a steady turn is Cog's own code.** The rest is Swift
runtime machinery, and two of its largest buckets were not in view before this
profile:

- **Generic metadata and dynamic casts, ~23% together.** `Cogs.state(_:create:)`
  casts the stored existential back to a concrete `State` on every lookup
  (Cogtext.swift:764), and `manualState(for:)` and `derivedState(for:)`
  instantiate `ManualCogState<Value>` and `DerivedCogState<Value>` metadata to
  do it. The settle walk then casts `state as? any DerivedCogSettleState`
  **twice per node per turn** — once entering and once exiting
  (CogSettle.swift:340 and :359) — and once more per boundary
  (CogObservationBoundary.swift:214). Part of that traffic reaches
  `_dyld_find_protocol_conformance_on_disk`, the uncached lookup path.
- **Actor-isolation checks, ~12%.** `CogState.addSubscriber(_:)` pays
  `swift_task_isCurrentExecutor` and main-executor resolution on every
  dependency re-record (CogSettle.swift:79–80), as does
  `CogObservationBoundary.notifyValueChange()`. The per-turn `CogTurn` and
  `CogTurnID` pair pays them again in `isolated deinit`, so allocation 3 and
  allocation 4 cost more than their mallocs.

**Pinned-key slope, both cores.** One keyed source written and read; every
other key pinned and untouched.

| Pinned keys | simple retains / releases | arena retains / releases |
| ----------: | ------------------------: | -----------------------: |
|           1 |                  78 / 104 |                  56 / 78 |
|         100 |                 177 / 203 |                254 / 276 |
|         500 |                 577 / 603 |            1,054 / 1,076 |
|       1,000 |             1,077 / 1,103 |            2,054 / 2,076 |

Exactly one retain and one release per pinned key on simple, exactly two on
arena — the `M6-12a` result, reproduced independently. At a thousand pinned
keys **79.9% of the turn's leaf samples are ARC**, and the site is one line:
`flushClassObservationBoundaries` iterates `observationStates`, an array of
`any CogObservationState`, retaining and releasing every element whether or not
it changed (CogObservationBoundary.swift:212).

**Per-node settle cost, depth-100 keyed chain.** One source write pulled
through a hundred derived nodes.

| Core   | mallocs / turn | retains / turn | releases / turn | wall clock / turn |
| ------ | -------------: | -------------: | --------------: | ----------------: |
| simple |            107 |          4,176 |           4,902 |            118 µs |
| arena  |              5 |          1,254 |           1,376 |            101 µs |

Simple pays about **one allocation, forty-one retains, and forty-nine releases
per node per turn**. Leaf time on that shape is 33.9% ARC, 16.2% generic
metadata, 7.7% isolation checks, 7.1% dynamic casts, 5.8% weak loads, and 5.4%
exclusivity, against 5.0% for Cog's own code.

This chain is a keyed `CogBox` recursion, **not** the Kairo deep benchmark that
`M6-11c` measured a 33% instruction regression on. It is a different shape and
the two must not be compared; it is recorded because it isolates per-node cost,
which the Kairo shape does not.

**What the profile settles.** The ranking below is measurement, not the
code-reading that opened issue #373, and it reorders that issue's routes:

1. The boundary flush is the largest single defect and the one with a name
   already: it is four-fifths of a turn once a screen has scrolled, and it is
   `M6-12a`'s stated trigger for reconsidering the core.
2. Shared turn machinery, not representation, owns the steady turn. Four
   allocations, two `isolated deinit` executor-check pairs, and three arrays
   rebuilt from empty are all common-path cost that no core swap can reach.
3. Existential casts, generic metadata, and dynamic isolation checks are a
   third of a steady turn and were entirely absent from the code-reading
   diagnosis. They are shared machinery too.

Any rerun of the simple-versus-arena comparison before those three are fixed
would measure the same coat on both candidates, which is what `M6-12a` already
did. `M9-17` reruns it afterwards.

**Pinned-key work is O(changed)** — `M9-06`, 2026-08-19, `mactop` (Apple
Silicon arm64, 12 cores, 24 GB), macOS 26.4.1 / Darwin 25.4.0, Xcode 26.4
(17E192) / Apple Swift 6.3, release, harness 1.36.2. Same shape as `M5-07d`:
one keyed source written and read, every other key pinned and untouched.

| Pinned keys | simple retains / releases / p50 | arena retains / releases / p50 |
| ----------: | ------------------------------: | -----------------------------: |
|           1 |              71 / 89 / 2.490 µs |             55 / 70 / 3.154 µs |
|       1,000 |              71 / 89 / 2.402 µs |             55 / 70 / 3.174 µs |

**Identical at every percentile, on both cores.** `M5-07d` recorded one retain
and one release per pinned key on simple and `M6-11c` recorded two on arena;
both are now zero, and the thousand-key turn is no slower than the one-key
turn. Against the pre-M9 numbers the thousand-key shape falls from 1,067
retains and 26 µs to 71 retains and 2.4 µs.

Two changes, in order. `M9-03` moved the arena's `changedAt` guard above its
boundary-entry copy and descriptor lookup, which was expected to halve that
core's slope and removed it: the entry and the record were the whole of its
per-key ARC. `M9-04` and `M9-05` then replaced both flushes with a
changed-boundary queue filled where invalidation already visits a state, which
removed the residual scalar walk — worth 1.9 ns per key on the arena after
`M9-03`, and the entire difference on the simple core.

The queue costs a small constant: the simple core's one-key turn pays three
more retains than it did, for a thousand-key turn that pays 996 fewer.

**`M6-12a`'s condition is met.** It named "a candidate makes pinned-key work
O(changed)" as the trigger for reconsidering the core swap, and that is now
true of both cores rather than of a candidate. `M9-17` reruns the comparison.
Worth noting ahead of it: on this shape the shipping core is now the faster of
the two, 2.402 µs against 3.174 µs.

**The gate.** `perf-11-pinned-key-slope-1000` carries a committed p90 ceiling of
90,000 retains and 110,000 releases — raw sums, so 90 and 110 per operation,
against the 71 and 89 measured. It is an absolute ceiling rather than a drift
tolerance because the claim is absolute: a thousand pinned keys must cost what
one costs. `M9-06` verified the gate bites by tightening the ceiling below the
measured value and watching the same command fail.

**Ceilings are raw sums, and the report prints scaled figures.** A ceiling of
90 rather than 90,000 passes against a measured 71,000 while reading, in the
source, exactly like the intended gate. `M5-11` recorded the same trap for
baseline tolerances; `M9-06` walked into it for static ceilings and is
recording it beside the number so the next reader does not.

**A steady turn allocates nothing** — `M9-10`, 2026-08-19, `mactop`, Xcode 26.4
(17E192) / Apple Swift 6.3, release, harness 1.36.2 with the malloc interposer.
Same benchmark and same shape as `M5-06`, which recorded seven.

| Metric             |  `M5-06` |      now |
| ------------------ | -------: | -------: |
| `mallocCountTotal` |        7 |    **0** |
| `objectAllocCount` |        7 |    **0** |
| retains            |       66 |       63 |
| releases           |       93 |       76 |
| p50 wall clock     | 2.202 µs | 1.676 µs |

Zero at every percentile across 1,751 samples, on the **class-state core**, and
without changing representation. `M6-12a` recorded the arena reaching five
rather than zero and concluded the swap did not earn itself; the target was
never the representation's to reach, because none of the seven allocations was
graph storage.

Where the seven went, in the order they were removed:

| Allocation             | Removed by | What it was                                                                          |
| ---------------------- | ---------- | ------------------------------------------------------------------------------------ |
| invalidation work list | `M9-09`    | a local array grown from zero every changed source                                   |
| dependency list        | `M9-09`    | reallocated by copy-on-write, because the previous list was copied rather than moved |
| `CogOps` write box     | `M9-07`    | an escaping closure for a single write                                               |
| `withTurn` body box    | `M9-07`    | a second escaping closure, one layer down                                            |
| `CogTurnID`            | `M9-08`    | an object whose only job was to be compared by identity                              |
| `CogTurn`              | `M9-08`    | per-turn state that one reused object holds                                          |
| touched-source list    | `M9-08`    | grown from zero capacity because its owner was new each turn                         |

A commit with no read is also zero, and so is a turn that settles a hundred-node
chain — `M9-01` measured that shape at 107 allocations, one per node, all of
them the copy-on-write defect.

The gate is exact rather than a tolerance now, matching PERF-06: a claim of
nothing is checkable exactly, and a tolerance around nothing would hide the
first allocation to come back. `perf-01-steady-turn` joins the committed
static-threshold set, so CI enforces zero rather than pinning drift.

**Retains and releases did not reach zero**, and are not close: 63 and 76 for a
turn with one consumer. That is §5's rule still unmet, and it belongs to the
routes issue #373 keeps — borrowed descriptor records, unsafe buffers, and the
hashing follow-ups — not to a core swap. `M9-17` remeasures before anything
else is promoted.

**What a steady turn is made of now** — `M9-12`, 2026-08-19, same host and
toolchain, 5,100 leaf samples over a 1.53 µs turn. The `M9-01` profile is the
before; this is the after, and it is what the remaining routes are chosen from.

| Bucket                               | `M9-01` |      now |
| ------------------------------------ | ------: | -------: |
| ARC retain and release               |   23.5% |    28.5% |
| Generic metadata instantiation       |   19.0% |    18.6% |
| Exclusivity checks                   |    8.2% |    12.5% |
| **Cog's own compiled code**          |    6.1% | **9.1%** |
| Actor-isolation checks               |   12.4% |     8.9% |
| Weak-reference loads                 |    5.1% |     5.8% |
| Dynamic casts and conformance lookup |    4.2% |     1.1% |
| malloc and free                      |    5.5% | **0.0%** |

Allocation is gone, casts are nearly gone, and isolation checks are down by a
third. The shares that grew did so because the turn shrank around them.

**Generic metadata is now the largest addressable cost**, and it is
concentrated: `manualState(for:)` and `derivedState(for:)` account for most of
it, because resolving a descriptor and key goes through a function generic over
the concrete state class, so every read asks the runtime for
`ManualCogState<Value>` or `DerivedCogState<Value>` metadata.

`M9-12` measured the cheap version of this and rejected it. Replacing the
lookup's checked cast with `unsafeDowncast` is worth 5% of a steady turn — and
the cast guards an internal invariant, so a violation is a Cog bug rather than
bad input, and an unchecked cast converts a clear release-build error into
undefined behavior. §1 rule 2 is not tradeable against §1 rule 3 at that price.
Marking the two lookups `@inline(__always)` alongside it measured within noise.

The version that keeps the check is a per-context cache on the declaration's
descriptor, which removes the dictionary hash and the metadata request together
because the descriptor is already the concrete generic type. That is issue
#373's route D, and it needs its own lifetime-release coverage before it is
worth landing.

**Settling a node allocates nothing** — `M9-15`, 2026-08-19, same host and
toolchain. One source pulled through a hundred derived nodes, every turn, on a
graph built and settled once outside the measured region.

| Metric             | before M9 |    now | per node |
| ------------------ | --------: | -----: | -------: |
| `mallocCountTotal` |       107 |  **0** |        0 |
| `objectAllocCount` |       107 |  **0** |        0 |
| retains            |     4,176 |  3,964 |     39.6 |
| releases           |     4,902 |  4,577 |     45.8 |
| p50 wall clock     |    124 µs | 130 µs |   1.3 µs |

The before column is `M9-01`'s probe rather than this benchmark, which did not
exist then; the shapes match but the harnesses do not, so read the allocation
rows — which are exact — rather than the wall-clock row, which is not
comparable.

**One allocation per node became none**, and it was never per-node work: the
dependency list reallocated on every recompute because `run(in:)` copied the
previous list instead of moving it, so `removeAll(keepingCapacity:)` had a
shared buffer and could keep nothing (`M9-09`). A hundred nodes meant a hundred
copies of that one mistake. This is also most of what the arena's five-versus-107
advantage on deep shapes was measuring in M6.

**ARC is not zero and is not close**: about forty retains and forty-six
releases per node. §5's "no ARC in graph walks" rule remains unmet on the
correctness core, which walks class states through existentials and retains at
every hop. The gate reflects that honestly — allocations are held at exactly
zero, ARC is pinned against drift — and the routes that would close it are
instruction-level work still on issue #373.

**The core comparison, rerun after M9** — `M9-17`, 2026-08-19, `mactop`, Xcode
26.4 (17E192) / Apple Swift 6.3, release, harness 1.36.2. The same benchmarks
`M6-11c` ran, in one session, on both selectors, after the shared machinery both
cores were wearing came off.

> **This record's arena figures are superseded and its verdict no longer
> holds.** `M9-22` and `M9-23` landed after it and took 21% and a further 22%
> off the arena's turn, which reversed the deep-graph result this table reports
> as a 20% loss. Read it as the state of the comparison at that moment; for the
> current one, read `M9-23` for the steady turn and whole-graph shapes, `M9-25`
> for build cost, and `M9-26` for where that cost goes. The simple-core column
> still stands — nothing after this changed it.

Cost benchmarks, per operation:

| Workload          | Core   | mallocs | retains / releases | p50 wall clock |
| ----------------- | ------ | ------: | -----------------: | -------------: |
| steady turn       | simple |   **0** |            62 / 75 |   **1.639 µs** |
| steady turn       | arena  |       1 |        **47 / 56** |       2.198 µs |
| 16-consumer fan   | simple |   **0** |      1,158 / 2,041 |          37 µs |
| 16-consumer fan   | arena  |       1 |      **409 / 478** |      **21 µs** |
| 100-node chain    | simple |   **0** |      3,963 / 4,576 |         128 µs |
| 100-node chain    | arena  |       1 |  **1,248 / 1,257** |     **109 µs** |
| 1 pinned key      | simple |   **0** |            65 / 78 |   **2.072 µs** |
| 1 pinned key      | arena  |       1 |        **50 / 59** |       2.861 µs |
| 1,000 pinned keys | simple |   **0** |            65 / 78 |   **2.159 µs** |
| 1,000 pinned keys | arena  |       1 |        **50 / 59** |       2.902 µs |

Whole-graph runtimes:

| Workload |   simple p50 |    arena p50 | simple instructions | arena instructions |
| -------- | -----------: | -----------: | ------------------: | -----------------: |
| diamond  |     4,551 µs | **4,219 µs** |            **84 M** |              102 M |
| deep     | **2,279 µs** |     2,724 µs |            **43 M** |               68 M |
| broad    |        12 ms |  **9.08 ms** |               221 M |          **217 M** |
| unstable |     2,410 µs | **1,248 µs** |                43 M |           **31 M** |

**Two positions swapped.** M6 recorded the simple core allocating seven times
per steady turn against the arena's five, and that was one of the two cost
targets the swap was chartered to meet. It is now zero against one: the
shipping core allocates nothing on every cost benchmark here, and the arena
still allocates once. The other target, zero ARC in graph walks, is still
unmet by both, and the arena is still three to four times better at it.

**The shape of the trade did not change; its terms did.** The arena still wins
wide and dynamic graphs decisively — broad by 24%, unstable by 48% — and still
loses deep, now by 20% in wall clock and 58% in instructions where M6 measured
4% and 33%. The smallest turn, which M6 had the arena losing by 10%, it now
loses by 34%, and the pinned-key shapes it now loses by about 35% despite
carrying less ARC.

That last pair is the interesting one. Both cores make pinned-key work
O(changed) after `M9-03` and `M9-05`, so the comparison is no longer about
scaling at all — and with scaling neutralised, the constant favours the simple
core.

**What M9 changed about the question.** `M6-12a` deferred the decision until a
candidate made pinned-key work O(changed). That has happened, and it happened
in shared machinery rather than in a representation, which is the substance of
the answer: the defect was never the class-state core's to fix by being
replaced. What remains is a genuine representation difference — the arena's ARC
traffic is three to four times lower, and that is §5's rule, still unmet by the
shipping core and still the largest single item in a steady turn.

**Where the arena's ordinary turn goes** — `M9-21`, 2026-08-19, same host and
toolchain, 5,118 leaf samples. Recorded because the `M9-17` comparison shows
the arena losing the smallest turn by a third, and the reason turns out to have
nothing to do with its representation.

| Bucket                         | simple |     arena |
| ------------------------------ | -----: | --------: |
| ARC retain and release         |  28.5% |  **6.5%** |
| Exclusivity checks             |  12.5% | **31.7%** |
| Generic metadata instantiation |  18.6% | **26.0%** |
| Cog's own compiled code        |   9.1% |     12.2% |
| Value-witness copies           |   5.3% |      8.2% |
| Actor-isolation checks         |   8.9% |      2.2% |

**The arena won the argument it was built for and lost two nobody had.** Its
ARC traffic is a fifth of the simple core's, which is §5's rule working exactly
as designed. It then spends that gain, and more, on exclusivity checks and
metadata requests that the class-state core mostly does not make.

Attribution, by the Cog frame beneath each cost:

| Cost        | Site                                     | Samples |
| ----------- | ---------------------------------------- | ------: |
| metadata    | `CogArenaCore.manualRecord(for:)`        |     531 |
| metadata    | `CogArenaValueColumn.installedRow(for:)` |     527 |
| exclusivity | `CogArenaStorage.index(of:)`             |     382 |
| metadata    | `CogArenaValueColumn.commit(at:)`        |     384 |
| metadata    | `CogArenaValueColumn.stage(_:at:)`       |     359 |
| metadata    | `CogArenaCore.manualLocation(for:)`      |     292 |
| exclusivity | `CogArenaCore.settle(_:in:)`             |     175 |

Two shapes, and both are already named in perf §5 and issue #373 as reserved
work nobody had priced:

**Exclusivity, ~32%.** The arena's columns are mutable stored properties on
classes, so every `arena.flags[row]` and every column touch pays a dynamic
exclusivity check with its thread-local bookkeeping. §5 reserved the fix —
borrow each column once per turn phase rather than per access — and route E
separately noticed that `index(of:)` re-validates a generation on nearly every
column touch, which `CogArenaStorage.swift` itself anticipates hoisting. They
are the same 382 samples seen from two directions.

**Metadata, ~26%.** Resolving one value walks record → location → column → row,
and every layer is generic over the value type, so each asks the runtime for
`CogArenaValueColumn<Value>` metadata it has already been given. This is the
simple core's `M9-12` problem with more layers, and the same remedy applies:
cache the resolved location on the declaration's descriptor per context.

Together those two are about 1,240 ns of a 2,150 ns turn, against a 510 ns gap
to the simple core. Neither would close it entirely; both are aimed well past
it, and the metadata fix would narrow rather than close because it helps the
simple core too.

**The arena's exclusivity cost, removed** — `M9-22`, 2026-08-19, same host and
toolchain. `M9-21` measured dynamic exclusivity enforcement at 31.7% of the
arena's ordinary turn, the largest single cost in that core.

| Measure               |   before |        after |
| --------------------- | -------: | -----------: |
| steady turn p50       | 2,152 ns | **1,696 ns** |
| allocations           |        0 |            0 |
| retains / releases    |  45 / 53 |      46 / 54 |
| 1 pinned key p50      | 2,861 ns | **2,390 ns** |
| 1,000 pinned keys p50 | 2,902 ns | **2,441 ns** |

**21% off the smallest turn, and the everyday gap to the shipping core all but
closes**: 1,696 ns against 1,639 ns, where `M9-17` measured 2,152 against 1,639.
The pinned-key slope stays flat.

The change is `@exclusivity(unchecked)` on the arena's scalar columns — the
storage columns, the core's frame and record buffers, and the propagation
stack. Each is a mutable stored property on a class, so every touch was
bracketed by `swift_beginAccess`/`swift_endAccess` with thread-local
bookkeeping, and one turn touches them dozens of times.

Safe by construction rather than by convention, on three counts recorded in
`CogArenaStorage`: the classes are `@MainActor`, so no second thread can hold an
access; every element type is trivial, so no destructor — library or user — can
run inside an access and re-enter; and no method holds an access open across a
call. The third is an invariant a later edit could break, so it is written into
the source as an instruction rather than left to be rediscovered.

**The typed value columns keep full enforcement.** Their element type is the
user's, and releasing one can run arbitrary `deinit` code inside an access.
Annotating them measured a further 4.4%, and it was declined: an exclusivity
trap with a clear message is worth more than 100 ns in a research core.

Two things this settles about perf §5's reserved work. The per-phase
`withUnsafeMutableBufferPointer` borrow **does not apply here**: every hot loop
calls back into the arena inside its body — `settle` reaches a user selector,
the propagation loop reads `flags` through the edge storage — and `Array`'s
borrow leaves an empty array in place for the duration, so re-entry would read
zero rows rather than trap. That is strictly more dangerous than the attribute
for the same win. And the whole-library `-enforce-exclusivity=unchecked` flag,
also reserved there, measures 1,601 ns against this change's 1,696 — most of
the win for a fraction of the blast radius, which is why the targeted attribute
is what landed.

**The arena's metadata cost, and where the everyday gap went** — `M9-23`,
2026-08-19, same host and toolchain. `M9-21` measured generic-metadata
instantiation at 26% of the arena's ordinary turn; `M9-22` removed the
exclusivity third; this removes most of the metadata third.

| Measure             |  `M9-17` |  `M9-22` |          now | simple core |
| ------------------- | -------: | -------: | -----------: | ----------: |
| steady turn p50     | 2,198 ns | 1,696 ns | **1,337 ns** |    1,639 ns |
| steady retains      |       47 |       46 |       **38** |          62 |
| 16-consumer fan p50 |    21 µs |        — |    **13 µs** |       37 µs |
| 100-node chain p50  |   109 µs |        — |    **94 µs** |      128 µs |
| allocations         |        0 |        0 |            0 |           0 |

**The arena is now the faster core on every shape except keyed reads.** `M6-11c`
had it losing the smallest turn by 10% and `M9-17` by 34%; it now wins it by
18%, having never changed its representation.

The change memoizes a keyless declaration's resolved column and slot on its
descriptor, per context. That skips a `recordsByIdentity` lookup, a
`CogStateIdentity` construction, a `slots` lookup, and — the expensive part — the
`record.column as? CogArenaValueColumn<Value>` downcast that instantiated the
metadata. Resolution sites in the profile go from 405 samples to 8.

Two design points worth keeping:

**Context identity is a monotonic counter, not an `ObjectIdentifier`.** A
deallocated `Cogs` address is reusable, so a memo matched against a recycled
address could serve another context's state — an ABA hazard with a
cross-context correctness failure at the end of it. A never-reused counter
cannot be impersonated.

**The memo validates itself rather than trusting its invalidation hooks.**
Releasing a row advances its generation before the index can be reused, so a
stale memo fails `arena.contains(slot)` on its own. The explicit eviction on
release and on context teardown is hygiene; correctness does not depend on
having found every path. Descriptors outlive contexts — they are `static let` —
so this is the property that matters.

**Keyed references keep the old path**, deliberately: `box[key]` would need a
per-key memo and a wider invalidation surface for a shape this measurement does
not cover. It shows in the numbers — the arena's pinned-key turn is unchanged at
about 2.6 µs against the simple core's 2.2 µs, and that is now the only everyday
shape where the arena loses.

**The remaining metadata is not reachable this way.** 782 of the 1,007 residual
samples are inside `CogArenaValueColumn` itself — `installedRow`, `stage`,
`commit`, `current` — where the cost is `ContiguousArray<Value?>` access in
unspecialized generic code. No per-call-site cache helps that; it needs
specialization, which is a different route.

**Footprint and build cost, both cores** — `M9-25`, 2026-08-19, same host and
toolchain. Issue #373 route F asked for this: §9.6 had a per-state figure for
the simple core and none for the arena. Seven paired runs of PERF-03's
thousand-state graph — five hundred keyed sources and five hundred keyed
consumers, built and settled in a fresh context every iteration.

| Measure                        | simple        | arena         |
| ------------------------------ | ------------- | ------------- |
| resident-memory delta, p50, KB | 1,279–1,656   | 1,082–1,918   |
| median of those medians        | ~1,345        | ~1,541        |
| build + settle + teardown, p50 | **~1,068 µs** | **~2,320 µs** |

**The memory difference is not a result.** The arena's median runs about 15%
higher, and the ranges overlap so heavily — the arena's best run is below the
simple core's worst — that seven pairs cannot separate them. This is the metric
§9.6 already flags as sampled rather than counted: resident memory is
page-granular and the delta only advances on iterations where the peak actually
moves, which is why its gate is a whole mebibyte. Anyone wanting a real answer
needs a counted probe of the columns and dictionaries, not this benchmark.

Recorded because the first pair measured suggested a clean 48% difference and
it did not survive being run again. Route F remains open; what it now has is a
reason not to trust a single pair.

**The build cost is a result**, and a large one. Constructing, settling, and
releasing a thousand-state graph takes the arena **2.2× as long**, consistently
across every run with little spread. That is cold-start cost and the cost of a
screen materialising a large keyed family, and it is the first measurement that
favours the simple core by a wide margin on a shape a real app hits.

Worth reading beside the steady-state numbers, which favour the arena on every
whole-graph shape after `M9-22` and `M9-23`. The arena is faster to _run_ and
slower to _build_; nothing measured so far told us the second half.

**Where the arena's build cost goes** — `M9-26`, 2026-08-19, same host and
toolchain. `M9-25` established the 2.2× and did not explain it, so the `M9-01`
probe gained a `build` workload: PERF-03's exact shape, a fresh context per
iteration, so everything the other workloads deliberately push behind their
warm-up is the measured region instead. One build of a thousand states:

| Counter     | simple | arena      |
| ----------- | ------ | ---------- |
| allocations | 4,525  | 5,697      |
| retains     | 22,504 | **17,527** |
| releases    | 38,052 | **24,745** |

**Neither counter explains it.** Allocations are 26% higher, which cannot
produce 2.2×, and ARC is 22% _lower_ — the arena genuinely touches fewer
reference counts building a graph, exactly as its design intends. The cost is
in leaf CPU time that no counting metric sees, so it needs `sample`. Six
seconds each, bucketed by leaf symbol as §9.6's table is:

| Bucket                            | simple | arena     | absolute change |
| --------------------------------- | ------ | --------- | --------------- |
| generic metadata + witness tables | 17.7%  | **28.6%** | **~3.5×**       |
| unspecialized generic value work  | 25.7%  | 30.5%     | ~2.6×           |
| array growth and copying          | 1.5%   | 6.8%      | ~10×            |
| dictionary and `AnyHashable` keys | 12.2%  | 9.3%      | ~1.7×           |
| ARC                               | 13.0%  | 3.3%      | ~0.55×          |
| dynamic casts, conformance lookup | 10.9%  | 3.1%      | ~0.63×          |
| Cog's own code                    | 8.4%   | 10.0%     | ~2.6×           |

Percentages are of each core's own run; the absolute column multiplies them by
`M9-25`'s 2,320 µs against 1,068 µs, which is the comparison that matters. The
two runs sampled almost identical leaf totals (4,808 and 4,817), so the shares
are directly comparable as fractions of time.

**The cost is the erased-storage crossing, not the layout.** A simple-core
state is one object whose fields are concrete and inline. An arena state is
split across the scalar columns and a per-descriptor generic
`CogArenaValueColumn<Value>`, reached through the `AnyObject` in
`CogArenaDescriptorRecord` and recovered as its concrete type at each touch.
That crossing is what instantiates metadata and looks up witness tables, and
construction pays it per state.

Construction pays it and a steady turn largely does not, because `M9-23`'s memo
files the resolved slot-and-column pair on the declaration — **and only for a
keyless one**, since one declaration names a whole keyed family and a
single-entry memo would thrash between its members. PERF-03 is a hundred
percent keyed. So the build workload is precisely the path the memo does not
cover, which is the same reason the arena still loses keyed lookups. The two
findings are one finding.

This also names what a fix would have to be. Nothing here is wasted work that a
cache can skip a second time; it is unspecialized generic code, so the route is
specialization, which is the same conclusion `M9-24` reached from the steady
turn. Route F's remaining question is whether that is reachable without
widening the public API.

**The Storefront macrobenchmark: what it is, and what it is not** — `M10-01`,
2026-08-19. Every benchmark above measures a _shape_ — a diamond, a fan, a
chain, a thousand keyed states — chosen because it isolates one cost. The
Storefront measures a composed application instead: one commerce session driven
through named domain verbs, headlessly and again through a real SwiftUI
interface.

It is a **representative workload v1**, and the phrase is doing work. There is
no such thing as a typical application without production telemetry, so the
scale below is an explicit, configurable, asserted choice rather than a claim
about real apps. `StorefrontShapeTests` checks every number in this table
mechanically, so a workload that quietly grew a declaration fails before it
makes two recorded numbers incomparable.

| Property                           | `smoke` | `standard` |    `stress` |
| ---------------------------------- | ------: | ---------: | ----------: |
| Products                           |     120 |  **1,200** |       6,000 |
| Categories                         |       6 |     **24** |          48 |
| Distinct rows a session visits     |      24 |    **120** |         400 |
| Rows materialized at once          |      12 |     **30** |          40 |
| Prefetch margin, each side         |       4 |      **8** |          12 |
| Pricing policies (price books × 1) |       4 |     **16** | 16 × 3 = 48 |

| Declaration kind | Count |
| ---------------- | ----: |
| `ManualCog`      |    12 |
| `ManualCogBox`   |     5 |
| `Cog`            |    18 |
| `CogBox`         |     8 |
| `AsyncCog`       |     7 |
| `AsyncCogBox`    |     3 |

Two of those counts differ from the targets the workload was commissioned
against, and both adjustments are structural rather than cosmetic:

- **Seven keyless `AsyncCog`s, not five.** The commission also named the graph
  levels async state had to occupy: two roots (catalog, account), two mid-graph
  (search index, suggestions — plus recommendations), and two deep downstream
  (shipping quote, tax quote). Those levels do not fit in five keyless
  declarations, and merging shipping with tax would have deleted the fan-in a
  checkout screen actually has.
- **Five `ManualCogBox`es, not four.** The fifth is a per-product inventory
  _generation_. A keyless epoch would have been simpler and would have made the
  inventory-burst claim unprovable: bumping one epoch invalidates every demanded
  row, so "the offscreen half of the burst cost nothing" could not be
  distinguished from "the burst was cheap".

The longest meaningful dependency path is **23 nodes** — the async catalog, the
products it carries, the product index, the pricing ladder's base plus its
sixteen policy stages, the effective price, the row value, and the reaction that
observes it — and not one of them is an identity node.

What it covers: a search funnel over the whole catalog, per-row keyed async at
two depths, a recursive keyed pricing pipeline whose stages read _different_
parts of the graph, a multi-source `Writer` filter change, a cart whose totals
depend on two sibling async quotes, deliberate stale-generation and
supersession handling, and lifetime release after grace on an injected clock.

What it does not cover, and should not be read as covering: multiple screens
alive at once, a real navigation stack's worth of retained state, background
refresh under memory pressure, cold-launch disk I/O, any real network, and any
device that is not the one named beside a number. It is one session, one
shopper, one fixture seed.

**The Storefront macrobenchmark, first measurements** — `M10-05`, 2026-08-19,
`mactop` (Apple Silicon arm64, 12 cores, 24 GB), Xcode 26.4 (17E192) / Apple
Swift 6.3, release, harness 1.36.2 with the malloc interposer. Standard profile,
**simple core** (the shipping default). Report-only: no committed threshold, for
the reason `M5-11` records — a threshold with no repeated pinned-CI history
behind it is a guess.

| Cut                                  | p50 wall clock | instructions | mallocs | object allocs | retains | releases | samples |
| ------------------------------------ | -------------: | -----------: | ------: | ------------: | ------: | -------: | ------: |
| `perf-15-storefront-cold`            |         555 ms |      7,998 M |       — |             — |       — |        — |      10 |
| `perf-15-storefront-session`         |       6,178 ms |         88 G |       — |             — |       — |        — |   **2** |
| `perf-15-storefront-interactions`    |       1,340 µs |         20 M |      19 |            19 |    29 K |     79 K |   2,181 |
| `perf-15-storefront-async-burst`     |          80 ms |      1,158 M |       — |             — |       — |        — |      62 |
| `perf-15-storefront-compute-control` |         604 µs |         13 M |   5,603 |         1,838 |    11 K |     21 K |   4,167 |

The sample counts are part of the result. `-session` gets **two** samples inside
its ten-second budget on the simple core, which is enough to say the number is
about six seconds and not enough to say anything about its distribution; the
counted cuts get thousands and report byte-identical counts at every percentile.
Read the wall-clock rows accordingly.

Malloc and ARC counters appear on two cuts only. The other three build or drop a
runtime and accept async completions, which is exactly the non-quiescent shape
`M5-11` took those counters away from after a null `swift_release_hook` crash.

The compute-only control is reported **beside** the application cuts and never
subtracted from them. Differencing two noisy measurements produces a third,
noisier number that looks authoritative; printing both and letting a reader see
the ratio is honest and just as useful. The ratio here is the headline: the same
four algorithms over the same catalog cost **604 µs** with no graph and the cold
graph-backed screen costs **555 ms**, so on the simple core roughly three orders
of magnitude of a cold start is graph work rather than the application's own
arithmetic.

A sampler run over the cold cut puts that cost inside the reaction flush,
descending the pricing pipeline through `DerivedCogState.recompute` frame by
frame. The per-product term is roughly 6.7 M instructions and scales close to
linearly (300 → 1,720 M, 600 → 3,142 M, 1,200 → 7,998 M), so it is a constant
factor rather than an algorithmic blow-up. **Attributing that constant is not
done**, and `M10-09` owns the disposition.

**The Storefront macrobenchmark across cores** — `M10-08`, same host, toolchain,
and session. Both cores measured back to back on the standard profile, and every
cut checked its own visible identifiers, money totals, accepted generations, and
checksum before reporting, on both.

| Cut                                  | simple p50 | arena p50 |     arena is |
| ------------------------------------ | ---------: | --------: | -----------: |
| `perf-15-storefront-cold`            |     555 ms |     40 ms | 13.9× faster |
| `perf-15-storefront-session`         |   6,178 ms |    195 ms | 31.7× faster |
| `perf-15-storefront-interactions`    |   1,340 µs |     74 µs |   18× faster |
| `perf-15-storefront-async-burst`     |      80 ms |   6.23 ms | 12.8× faster |
| `perf-15-storefront-compute-control` |     604 µs |    657 µs |    unchanged |

| Counted metric, `-interactions` | simple | arena |
| ------------------------------- | -----: | ----: |
| `mallocCountTotal`              |     19 |    12 |
| `objectAllocCount`              |     19 |    12 |
| retains                         |   29 K |   903 |
| releases                        |   79 K |   950 |

The control row is the check on the other four: it contains no graph, so a core
swap must not move it, and it does not. Everything else moves by more than an
order of magnitude.

This is a different answer from the one the synthetic comparisons gave.
`M6-12a` and `M9-17` measured the two cores on diamond, deep, broad, and
unstable shapes and found them close enough that construction cost decided the
matter; `M9-25` and `M9-26` then measured the arena as **2.2× slower to build** a
thousand-state keyed graph. On a composed application the ordering reverses and
the margin is enormous — including on construction, which is what the cold cut
measures.

The most likely reason is the one the workload's shape makes obvious and the
synthetic shapes never did: this graph has two selectors with about **1,200
dependencies each** — the eligibility filter and the ranker both read one keyed
value per catalog product — and the simple core walks class states and
existentials over those lists on every settle, while the arena walks columns.
`perf-10`'s broad workload is wide, but it is not _this_ wide, and it is not
wide underneath a sixteen-deep keyed pipeline.

That is a measurement, not a decision. It is deliberately **not** treated here
as reopening `M6-12a`'s selected core: one workload on one host is exactly the
kind of evidence this document requires to be repeated in the pinned CI
environment before it moves anything. `M10-09` owns the disposition, and the
first question it has to answer is whether the simple core's wide-selector cost
is a defect with a fix rather than a reason to swap cores.

**What the Storefront graph costs to hold** — `M10-05`, 2026-08-19, same host
and toolchain, standard profile. `perf-15-storefront-footprint` builds the
catalog-wide keyed funnel — one eligibility state and one score state per
product, plus the two keyless nodes that gather them, **2,402 states** — and
measures it with the interposer's counters rather than with sampled resident
memory. The async roots are resolved before the measured region, so the region
is purely synchronous graph construction; every context is retained forever, so
no teardown can land in a later sample.

**What "survived" means here, exactly.** `mallocFreeDelta` is malloc calls minus
free calls _observed between `startMeasurement()` and `stopMeasurement()`_, and
`memoryLeakedBytes` is the same balance in requested bytes. They are a flow
balance across the measured window, not a census of the live heap, and three
consequences follow. A free inside the window, of memory allocated before it,
counts against the delta and can drive it negative. Something allocated inside
the window and freed a microsecond after the window closes still counts as
having survived. And "requested bytes" is what the program asked for — no
allocator size-class rounding, no malloc header, no page granularity, no
fragmentation — so it is a lower bound on resident growth rather than a measure
of it. Upstream's `memoryLeakedBytes` naming is a misnomer for a build-and-hold
region: here the retention is the answer, not a defect. The counters are also
process-global, which is why this cut may only exist at all in a region with no
async work and no teardown.

For this cut those caveats are small and known: the region opens on a fully
settled graph, closes one tracked read later, and the context is retained
forever, so the balance is very nearly "what materializing the funnel added".

Exact p90 integers, because the harness's own table rounds to K and M and
rounded allocation counts cannot be subtracted:

| Measure                                           |        simple |         arena |       ratio |
| ------------------------------------------------- | ------------: | ------------: | ----------: |
| allocations made (`mallocCountTotal`)             |        21,815 |        10,225 |       2.1 × |
| allocations returned (`freeCountTotal`)           |         3,761 |        10,150 |             |
| **allocations that survived** (`mallocFreeDelta`) |    **18,054** |        **75** |   **241 ×** |
| gross bytes requested (`mallocBytesCount`)        |     2,500,066 |     2,639,596 | about equal |
| **bytes that survived** (`memoryLeakedBytes`)     | **1,705,522** | **1,226,863** |  **1.39 ×** |
| object allocations                                |        19,333 |           198 |        98 × |
| retains                                           |    10,200,449 |        60,476 |       169 × |
| releases                                          |    30,371,379 |        59,387 |       511 × |
| instructions                                      |        7.10 G |         173 M |        41 × |
| wall clock                                        |        485 ms |       12.6 ms |        38 × |
| states materialized                               |         2,402 |         2,402 |             |

Three samples each. The simple core's counts are identical from p0 to p100; the
arena's surviving-allocation count moves between 51 and 75, which is one column
growing on some iterations and not others.

**The heap answer is not the one resident memory suggested.** Per state, the
simple core holds **710 bytes** and **7.5** surviving allocations; the arena
holds **511 bytes** and **0.031**. The arena's whole design shows up in that one
column: 2,402 states live inside a handful of columns rather than as 2,402
individually allocated objects, so it holds _fewer bytes_ while making two
hundred times fewer surviving allocations.

**And the ARC column is the mechanism from §9.6's core comparison, quantified.**
Thirty million releases to build 2,402 states is 12,644 releases per
state, which no per-state work can explain. It is `CogSettle.swift`'s
`addSubscriber`, which on every dependency read scans the producer's subscriber
list twice — once to prune dead weak edges, once to dedupe — and every element
touched costs a weak load, a retain/release pair, and a dynamic executor check
on a MainActor-isolated existential. The storefront has several producers read
by one to three thousand states each (`productIndex`, `queryTokens`,
`selectedCategory`, `inStockOnly`, `catalogProducts`), so that scan is quadratic
in fan. Summing `2 × Σk` over those producers predicts 30–60 M ARC operations
against 40 M observed. A sampler over the same cut puts 40% of the simple core's
time in executor checks, 33% in ARC, 20% in weak loads, and 12% in the
OS-version check inside the executor check — that is, essentially all of it in
that one loop, under four different frame names.

The arena's `recordDependency` walks a cursor down the consumer's existing edge
list and updates a version when the next edge names the same producer: O(1) when
dependency order is stable, integer indices throughout, no weak load and no ARC.
It maintains the same two directions; it is not doing less bookkeeping.

**Resident memory, with iteration counts pinned** — same session. The earlier
reading of these columns was taken with only a duration budget, which let the
arena run 135 cold iterations against the simple core's 10 and 54 sessions
against 2. That comparison said the arena's absolute peak was roughly twice the
simple core's; **it was mostly counting build-and-drop cycles, and it is
withdrawn.** With `maxIterations` pinned equal:

| Cut            | simple abs / Δ, p50 | arena abs / Δ, p50 | iterations |
| -------------- | ------------------: | -----------------: | ---------: |
| `-cold`        |    22 MB / 1,983 KB |   32 MB / 5,018 KB |         10 |
| `-async-burst` |      21 MB / 820 KB |     28 MB / 508 KB |         50 |
| `-session`     |    31 MB / 3,410 KB |   53 MB / 5,640 KB |          3 |

A gap remains — the arena's absolute peak runs about 1.5× the simple core's —
and it points the opposite way from the counted footprint, which is the
interesting part. The likeliest reading is transient rather than held: growing a
column copies it, so the old and new buffers are briefly resident together, and
`_platform_memmove` is the third-heaviest frame in the arena's profile. That
would raise a high-water mark without raising held bytes, which is exactly the
pattern the two instruments show. It is a reading, not a result: resident memory
is sampled and page-granular, and §9 already names reserving capacity from known
descriptor counts as the fix if it matters.

**Steady state allocates nothing net, on either core.**
`perf-15-storefront-interactions` reports `mallocFreeDelta` and
`memoryLeakedBytes` of **zero** at every percentile across thousands of samples
on both cores: a favorite toggle, a cart quantity, a variant selection, and a
two-source open-product verb allocate 19 (simple) or 12 (arena) and return all
of them. The compute-only control likewise nets zero and reports identical
figures on both cores — 5,603 allocations, 625 KB — which is the check that the
rows above mean what they say, since it contains no graph for a core swap to
change.

**The Storefront application, first measurements** — `M10-07`, 2026-08-19,
`mactop`, Xcode 26.4 (17E192), release configuration, on the **iPhone 17 Pro
simulator running iOS 26.4 (23E244), arm64**. The **smoke** profile, not the
standard one: a simulator UI run is six and a half minutes at 120 products and
the suite's job is to exercise the interface, not to restate the headless
scale. Five measured iterations per test, each preceded by a discarded warm-up
invocation, with the application relaunched to identical state outside every
measured region.

| Test                                | Metric                                        |    mean |   RSD |
| ----------------------------------- | --------------------------------------------- | ------: | ----: |
| cold launch                         | `ApplicationFirstFramePresentationResponsive` | 1.183 s | 1.32% |
| settled-feed scrolling              | `Scroll_DraggingAndDeceleration`              | 2.584 s | 0.01% |
| scrolling during an inventory burst | `Scroll_DraggingAndDeceleration`              | 2.567 s | 0.57% |
| search interaction                  | `XCTClockMetric`                              | 0.372 s | 1.54% |
| search interaction                  | CPU time, app process                         | 0.225 s | 3.37% |
| search interaction                  | instructions retired, app process             | 2.38 GI | 1.75% |
| search interaction                  | peak physical memory, app process             | 72.6 MB | 0.12% |
| detail navigation                   | `NavigationTransition`                        | 0.517 s | 0.34% |
| cart and checkout interaction       | `XCTClockMetric`                              | 2.234 s | 2.23% |
| cart and checkout interaction       | instructions retired, app process             | 3.18 GI | 0.21% |

Three things this run settled that no Apple document states, and that were
therefore assumptions until they were measured:

- **A SwiftUI `List` does emit the UIKit scroll signposts.**
  `XCTOSSignpostMetric.scrollingAndDecelerationMetric` produced data on a pure
  SwiftUI list. Apple documents that sub-metric as backed by UIKit-instrumented
  intervals and nowhere says whether SwiftUI participates; here it does.
- **`XCTHitchMetric` produced nothing.** The two scrolling tests carry
  `XCTHitchMetric(application:)` behind `@available(iOS 26.0, *)`, the runtime
  was iOS 26.4 so the guard was satisfied, and the metric contributed **zero**
  series — no error, no warning, no row. The tests keep it rather than pretend
  it was never asked for. **This suite therefore cannot produce a hitch number
  at all**, which is a coverage gap and not a passing grade.
- **`Scroll_DraggingAndDeceleration` reports duration, not smoothness.** Its
  0.011% relative standard deviation on the settled feed is not a compliment; a
  synthesized swipe's interval is dominated by the fixed gesture and
  deceleration time. It proves the list scrolls without stalling far more than
  it quantifies how smoothly.

**What these numbers are for.** They are a pinned regression signal against
themselves — same host, same pinned Xcode, same simulated device, same fixture,
same 76 pt row height, same locale and Dynamic Type setting. They are not
evidence about what a person holding an iPhone experiences. An absolute
hitch-ratio target belongs on a pinned physical device and nowhere else. Apple's
published guidance for the Xcode Organizer's Hitches metric — "A hitch rate at
or below 10 ms/s is good; at or below 25 ms/s is a warning; at or below 50 ms/s
is critical; and above 50 ms/s warrants immediate attention" — is about field
data from real devices reported through the Organizer, and is recorded here so
that nobody invents a different number, not because this suite is measured
against it.

Two figures are deliberately not in the table. The per-iteration physical-memory
_delta_ swings 39% and goes negative; the absolute and peak figures beside it
are stable to a tenth of a percent and are the ones worth tracking. And nothing
here is gated: the suite runs from `mise run test:storefront-ui` when a number
is wanted, not on every pull request, because a six-and-a-half-minute timing
test on a shared machine teaches people to rerun rather than to look.

**A zero threshold can pass because nothing was measured.** `M5-05bb` found
that a run with the malloc interposer disabled reports `mallocCountTotal == 0`
for a workload that demonstrably allocates. `perf-witness-allocating` exists as
the control — a benchmark that must always report a non-zero count — and
`M5-08a` owes the floor assertion, because upstream thresholds are upper bounds
and cannot express one.

## 10. Deliberate non-goals

- **No MVCC or snapshot record lists.** They solve multi-writer isolation,
  which a MainActor graph does not have.
- **No height-based eager recompute queue.** Lazy pull does not need state
  heights. Revisit only if an eager batch mode becomes a requirement.
- **No locks or atomics in the graph.** Async generation checks live at the
  concurrency boundary, not in graph storage.
- **No unmeasured representation choice.** Value-reference and edge layouts
  are settled by the measurements in §9.6; hash tables and exclusivity
  attributes wait for benchmarks.

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
