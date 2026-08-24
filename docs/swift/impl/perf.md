# Cog for Swift: the performance record

_August 25, 2026_

This document answers four questions:

1. What does Cog cost in normal app code?
2. How does it perform in a larger workload?
3. Which trade-offs shaped the shipping runtime?
4. What should be improved next?

It records the current build. Older results and retired designs live in
[perf-history.md](./perf-history.md). The benchmark design lives in
[design/perf.md](../design/perf.md). Commands and tool versions live in the
[`swift/Benchmarks` README](https://github.com/skeswa/cog/blob/main/swift/Benchmarks/README.md).
If a number here conflicts with `perf-history.md`, use this one.

## The short answer

- A warm, keyless state update takes well under 1 µs and allocates nothing.
- A Storefront interaction takes about 140 µs. That is under 2% of one 120 Hz
  frame on the measured host.
- Cog is about 2× to 3× slower than careful hand-written memoization in the
  Storefront workload. It uses fewer allocations and removes the need to
  maintain invalidation lists by hand.
- Cog is about 10× faster than swift-state-graph on a steady Storefront
  interaction and 10× to 20× faster on the synthetic graph shapes.
- Keyed state and cold construction are the clearest remaining gaps.
- The default specialized arena favors speed. `CompactArena` saves about 6% of
  the measured library code segment but makes graph construction slower.

These are benchmark results, not promises for every app. Each number links to
an environment ID such as [E14](#benchmark-environment-e14). All runs used
release builds. p50 is the median; p90 is the 90th percentile. Lower time,
instructions, allocations, retains, and releases are better. ARC means Swift's
reference-counting work.

## 1. What users should expect

Cog ships one runtime: the **specialized arena**. It stores state in columns
and edges in a shared integer pool. A typed frontier lets the compiler
specialize generic value work in the app. `CompactArena` turns off that
frontier to save code size.

### Common updates

These cuts give useful scale. They come from different sessions, so compare
them only as rough examples, not as one ranked test.

| Work                                      |     p50 | What it represents                                       | Environment                       |
| ----------------------------------------- | ------: | -------------------------------------------------------- | --------------------------------- |
| keyless steady turn                       |  709 ns | one source, one automatic value, one tracked read        | [E12](#benchmark-environment-e12) |
| keyed steady turn                         | 1.27 µs | the same shape, with keyed references                    | [E13](#benchmark-environment-e13) |
| update with 16 consumers                  |  7.6 µs | one source fans out to 16 values                         | [E5](#benchmark-environment-e5)   |
| settle a 100-node chain                   |   64 µs | one change flows through a deep dependency path          | [E5](#benchmark-environment-e5)   |
| settled Storefront interaction            |  144 µs | write state and settle a 23-node, 16-policy pricing path | [E14](#benchmark-environment-e14) |
| build and settle 1,000 fresh keyed states | 1.10 ms | 500 keyed sources and 500 keyed consumers                | [E5](#benchmark-environment-e5)   |

A 120 Hz frame lasts 8.3 ms. On these hosts, the first four operations use far
less than one frame.

> **User example:** A setting toggle with one derived label is close to the
> steady-turn case. Favoriting a product while totals and pricing update is
> closer to the Storefront interaction. The second case still used only about
> 1.7% of a 120 Hz frame in E14.

The keyless steady turn and the 100-node chain allocate nothing. Building the
1,000-state keyed graph allocates 1,699 times because it creates and keeps the
graph.

### What keys cost

E13 ran the same graph twice. The only change was whether every reference had
a key.

| Measure            | keyless |    keyed | added cost |
| ------------------ | ------: | -------: | ---------: |
| p50 wall time      |  582 ns | 1,267 ns |      2.18× |
| retains / releases | 18 / 25 |  27 / 34 |    +9 / +9 |
| mallocs            |       0 |        0 |          0 |

Only about 32 ns of the 685 ns gap came from ARC. Most of the gap came from
`AnyHashable`, hashing, generic metadata, witness lookup, and value copies.
Creating one `box[key]` reference costs about 65 ns. A keyed turn creates
three, so about 195 ns is the cost of the public `AnyHashable` shape itself.
The remaining roughly 490 ns may be reduced by a more specialized keyed path.

> **User example:** A single app-wide theme value should be keyless. Product
> inventory needs keys because one declaration represents many products. Use
> keys for real identity, but do not add them to values that only have one
> instance.

### Larger graph shapes

E9 compared Cog with raw `@Observable` and swift-state-graph 0.28.0. Raw
Observation is a floor, not a full competitor: it has no automatic-value cache
or dependency graph. Each result is p50 time and p50 instructions.

| Shape    | raw `@Observable` | Cog             | swift-state-graph | Cog vs. raw | Cog vs. state graph |
| -------- | ----------------- | --------------- | ----------------- | ----------: | ------------------: |
| diamond  | 788 µs / 16 M     | 1,530 µs / 37 M | 25 ms / 505 M     |        1.9× |          16× faster |
| deep     | 202 µs / 4.1 M    | 697 µs / 18 M   | 14 ms / 300 M     |        3.5× |          20× faster |
| broad    | 2,055 µs / 45 M   | 3,703 µs / 88 M | 36 ms / 721 M     |        1.8× |         9.7× faster |
| unstable | 324 µs / 7.1 M    | 471 µs / 12 M   | 7,471 µs / 153 M  |        1.5× |          16× faster |

Cog's cache, dependency tracking, and glitch-free settlement cost 1.5× to
3.5× over the raw floor. The deep chain has the largest gap because Cog walks
100 cache nodes that the raw version does not have.

## 2. Storefront: an app-sized example

<a id="storefront-macrobenchmark"></a>

Storefront runs an eleven-phase commerce session through four state runtimes.
All four use the same script, fixtures, async service, and shadow model. It is
a **representative workload v1**, not an average app.

The standard profile has 1,200 products, 24 categories, 120 visited rows, 30
live rows, an eight-row prefetch margin, and 16 pricing policies. Its longest
useful dependency path has 23 nodes. It covers search, keyed async state,
multi-source writes, stale results, replaced requests, cart totals, and release
after a grace period.

Tests also pin the other profile sizes:

| Property                     | smoke | standard | stress |
| ---------------------------- | ----: | -------: | -----: |
| products                     |   120 |    1,200 |  6,000 |
| categories                   |     6 |       24 |     48 |
| rows visited                 |    24 |      120 |    400 |
| rows held at once            |    12 |       30 |     40 |
| prefetch margin on each side |     4 |        8 |     12 |
| pricing policies             |     4 |       16 |     48 |

The Cog port declares 12 keyless manual values, 5 keyed manual families, 18
keyless automatic values, 8 keyed automatic families, 7 keyless async values,
and 3 keyed async families. Shape tests check those exact counts.

### The four runtimes

| Runtime            | Role in the comparison                                                                                                    |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------- |
| `cog`              | The workload written with Cog sources, automatic values, keyed selectors, async policies, and one assembly mechanism.     |
| `observation-raw`  | Plain `@Observable`. It recomputes every derived value on every read. This is the floor, not a realistic cached app.      |
| `observation-memo` | Plain `@Observable` plus seven hand-written caches and manual invalidation. This is the practical competitor.             |
| `state-graph`      | The same graph built with swift-state-graph 0.28.0 `Stored` and `Computed` nodes. This is the closest library comparison. |

### Cross-runtime results

Before E14, `mise run test:storefront-all` passed all four suites on the exact
working copy that was measured. Each runtime matched the same shadow model at
every checkpoint and ended with no outstanding requests.

All 22 Storefront cuts then ran in one session on one host. The harness chooses
units per row, so check whether a value uses µs, ms, or s.

**Cold start** builds the runtime and reaches the first complete screen. Ten
samples ran per runtime.

| Runtime            | wall p50 | wall p90 | instructions p50 |  CPU p50 |
| ------------------ | -------: | -------: | ---------------: | -------: |
| `cog`              |    19 ms |    20 ms |            487 M |    19 ms |
| `observation-raw`  | 1,526 ms | 1,548 ms |             31 G | 1,526 ms |
| `observation-memo` | 5,865 µs | 5,931 µs |             89 M | 6,611 µs |
| `state-graph`      |    56 ms |    57 ms |          1,337 M |    57 ms |

**Whole session** runs the complete trace. Three samples ran per runtime, so
the p90 column is not a useful tail measurement.

| Runtime            | wall p50 | wall p90 | instructions p50 | CPU p50 |
| ------------------ | -------: | -------: | ---------------: | ------: |
| `cog`              |   118 ms |   119 ms |          2,886 M |  124 ms |
| `observation-raw`  |     12 s |     13 s |            260 G |    12 s |
| `observation-memo` |    44 ms |    45 ms |            642 M |   50 ms |
| `state-graph`      |   771 ms |   775 ms |             19 G |  775 ms |

**Async burst** accepts and settles one inventory burst. Fifty samples ran per
runtime.

| Runtime            | wall p50 | wall p90 | instructions p50 |  CPU p50 |
| ------------------ | -------: | -------: | ---------------: | -------: |
| `cog`              | 3,426 µs | 3,586 µs |             63 M | 3,701 µs |
| `observation-raw`  |   731 ms |   738 ms |             15 G |   731 ms |
| `observation-memo` | 1,799 µs | 1,839 µs |             21 M | 2,109 µs |
| `state-graph`      |    17 ms |    17 ms |            409 M |    17 ms |

**Steady interaction** covers settled favorite, cart, variant, and multi-write
actions. This is the only cross-runtime cut that is quiet enough for
process-wide allocation and ARC counters.

| Runtime            | wall p50 | wall p90 | instructions p50 | samples |
| ------------------ | -------: | -------: | ---------------: | ------: |
| `cog`              |   140 µs |   149 µs |          3,895 K |   2,787 |
| `observation-raw`  |   115 ms |   118 ms |          2,657 M |      26 |
| `observation-memo` |    59 µs |    66 µs |          1,242 K |   3,178 |
| `state-graph`      | 1,569 µs | 1,611 µs |             40 M |   1,200 |

| Runtime            | mallocs | malloc bytes | objects | retains / releases |
| ------------------ | ------: | -----------: | ------: | -----------------: |
| `cog`              |      12 |        536 B |      12 |      2,117 / 2,161 |
| `observation-raw`  |   4,432 |        378 M |   4,432 |  8,218 K / 9,596 K |
| `observation-memo` |      74 |      6,035 B |      74 |      1,543 / 1,725 |
| `state-graph`      |   2,602 |        185 K |   2,492 |        38 K / 44 K |

Every runtime had a zero malloc/free difference inside the timed interaction.
The raw port completed only 26 samples before the three-second limit, so its
wall-clock spread is weak.

The practical reading is simple:

- Hand-written memoization is 1.9× to 3.2× faster than Cog across these four
  cuts. On the steady interaction, it is about 2.4× faster.
- Cog allocates 12 times per interaction. The memo port allocates 74 times.
- Cog is about 11× faster than swift-state-graph on the steady interaction.
- Recomputing every derived value is about 820× slower than Cog on that same
  interaction.

#### What the faster memo port costs to maintain

The memo port has 89 executable lines across 19 methods that say which caches
each write must clear. It uses seven broad caches. Its 16-policy pricing ladder
is one cache cell per product, so any pricing change recomputes the full ladder.
Cog tracks each stage from the reads in that stage.

> **User example:** If a developer adds a seventeenth pricing rule, the Cog
> version declares the values that rule reads. The memo version must also
> update every manual invalidation path that can affect the rule. Missing one
> path can leave a stale price with no compiler error.

The raw port has almost no cache code. That is why it is simple and why it
repeats so much work. The state-graph port had to add keyed-node dictionaries,
an async generation layer, and TTL eviction. Two choices favor that port: its
service is a constant instead of a graph node, and it detects browse runs by
comparing the output it last rendered. The comparison includes the cost of that
output check.

All three non-Cog ports also render explicitly at the end of a transaction.
Their tracking callbacks do not provide the same next-line settlement barrier
as Cog reactions. The Observation ports still register tracking scopes, so
their registration and notification costs remain in the sample. This is a
scheduling difference, not a defect in those libraries.

None of the three comparison runtimes has Cog's async-value primitive. Each
port therefore includes its own request generations, stale-result rule, and
demand handles. The raw port also caches request identity so a render cannot
start the same request again. It caches no derived value.

#### Behavior checked across runtimes

Each runtime declares these semantics. The shared trace tests them.

| Field                              | Cog | raw Observation | memo Observation | state graph |
| ---------------------------------- | --- | --------------- | ---------------- | ----------- |
| browse runs after a content change | 1   | 1               | 1                | 1           |
| browse runs after an equal write   | 0   | 1               | 0                | 0           |
| browse runs after an unseen change | 0   | 1               | 0                | 0           |
| account runs through sign-in       | 2   | 2               | 2                | 2           |
| unseen request starts              | 0   | 0               | 0                | 0           |
| releases unobserved values         | yes | no cache        | yes              | yes         |
| rejects stale generations          | yes | yes             | yes              | yes         |
| has per-generation refresh handles | yes | yes             | yes              | yes         |

The memo and state-graph ports match Cog on every field. That matters: careful
manual caching can reproduce Cog's visible behavior. Cog's benefit is not a
result that manual code cannot reach. It is automatic dependency tracking with
less invalidation code.

The raw port's zero unseen-request starts comes from the render shape, not from
state management. It never asks for products outside the visible window and
prefetch margin.

#### Cog-only Storefront results

E14 also reran all six Cog-only `perf-15` cuts through the generic driver.

| Cut                  | wall p50 | wall p90 | instructions p50 | mallocs |   bytes | samples |
| -------------------- | -------: | -------: | ---------------: | ------: | ------: | ------: |
| cold                 |    18 ms |    19 ms |            484 M |       — |       — |      10 |
| session              |   119 ms |   119 ms |          2,888 M |       — |       — |       3 |
| async burst          | 3,389 µs | 3,670 µs |             63 M |       — |       — |      50 |
| interactions         |   144 µs |   153 µs |          3,930 K |      12 |   536 B |   2,807 |
| footprint            | 3,033 µs | 3,159 µs |             84 M |     177 | 2,220 K |       3 |
| compute-only control |   468 µs |   481 µs |             13 M |   5,611 |   625 K |   5,913 |

The footprint held 2,402 states. It kept 51 allocations and 1,208 K requested
bytes after the timed region. The control kept none. The matching `perf-15`
and `perf-16-cog` cuts agreed within normal run noise, including the exact 12
interaction allocations. This checks that the generic driver did not change
the Cog workload.

There is no cross-runtime footprint cut. The shared runtime API has no neutral
operation that starts the catalog and search index without materializing the
rest of the funnel.

#### SwiftUI results

E8 ran the Cog app in release on an iPhone 17 Pro simulator. All eight tests
passed, with five samples per metric.

| Measure                                   |           median |
| ----------------------------------------- | ---------------: |
| cold launch to responsive first frame     |          1.194 s |
| settled scroll signpost                   |          2.568 s |
| scroll signpost during an inventory burst |          2.567 s |
| detail navigation                         |          0.518 s |
| search wall time                          |          0.382 s |
| search CPU / instructions                 | 0.212 s / 2.28 G |
| search peak physical memory               |          73.3 MB |
| cart checkout wall time                   |          2.257 s |
| cart checkout CPU / instructions          | 0.354 s / 3.17 G |

The settled and inventory-burst scroll times differ by less than 1.5 ms. In
this test, offscreen inventory writes did not slow the visible scroll.
`XCTHitchMetric` produced no series on the simulator, so there is no hitch
number. Simulator results are regression signals, not device guarantees. Only
the Cog port has a UI app today.

#### Limits of the Storefront comparison

- E14 is one session on `koomac`, not a set of repeated sessions on the pinned
  benchmark runner.
- Storefront is one commerce shape. A chat app, document editor, or map may
  rank the runtimes differently.
- Cog maintainers wrote all ports against a Cog-shaped workload. A library
  author may find a better port.
- Cold start has 10 samples, the whole session has 3, and the raw interaction
  has 26. Their p90 values are not strong tail data.
- Storefront does not cover real network or disk work, memory pressure,
  several live screens, full navigation history, or physical devices.

## 3. Why the runtime is built this way

### <a id="typed-frontier-and-shipping-choice"></a>The typed frontier is the default

The arena once took 2,163 µs to build and settle 1,000 keyed states. Profiles
showed repeated generic metadata and unspecialized value work at its erased
storage boundary. The typed frontier made the value-typed entry points
`@inlinable`, which lets the app compiler specialize them.

Seven paired E5 runs measured the result:

| Measure             | frontier off | frontier on | change |
| ------------------- | -----------: | ----------: | -----: |
| median p50          |     2,163 µs |    1,102 µs | -49.1% |
| median instructions |         55 M |        27 M |   -51% |
| probe allocations   |        5,697 |       1,699 | -70.2% |

The stable frontier matched a temporary compiler-attribute experiment without
using an underscored attribute. The trade-off is code size and stability:
`@inlinable` bodies and the `@usableFromInline` symbols they call must remain
compatible with client builds.

### <a id="compactarena-what-the-size-opt-out-costs"></a>`CompactArena` trades speed for size

`CompactArena` keeps the arena and edge pool but turns off the typed frontier.
The public API and behavior stay the same.

Retained clean arm64 release artifacts measured the library's Mach-O `__TEXT`
segment. These artifact measurements have no environment ID.

| Artifact            |     default | `CompactArena` |            saved |
| ------------------- | ----------: | -------------: | ---------------: |
| `CogGraph` `__TEXT` | 2,670,592 B |    2,506,752 B | 163,840 B (6.1%) |

E7 ran both configurations back to back on the standard Storefront profile.
The comparison is still useful as a ratio, though its absolute numbers predate
the generic Storefront driver.

| Cut                  | default p50 | compact p50 | compact cost | default / compact instructions |
| -------------------- | ----------: | ----------: | -----------: | -----------------------------: |
| cold                 |       21 ms |       33 ms |         +57% |                  457 M / 793 M |
| session              |      131 ms |      169 ms |         +29% |              2,741 M / 3,756 M |
| interactions         |      178 µs |      197 µs |         +11% |                4.01 M / 4.52 M |
| async burst          |     3.74 ms |     3.99 ms |          +7% |                    63 M / 68 M |
| footprint            |     3.60 ms |     7.43 ms |        +106% |                   81 M / 174 M |
| compute-only control |      529 µs |      542 µs |        +2.5% |                    13 M / 13 M |

The default and compact interaction cuts both allocated 12 times. Their
controls both allocated 5,611 times. The compact footprint build allocated
about 10,000 times, compared with 177 for the default, because generic cold
storage allocates more.

> **User example:** Choose `CompactArena` only when executable size matters
> more than startup and graph-build speed. Because SwiftPM traits are additive,
> an app should make this choice. A reusable library should not force it.

The measured whole Storefront `__TEXT` was 991,232 bytes with the frontier on,
19.8% larger than the retired simple-core app. No compact Storefront artifact
or post-driver-lift paired run exists yet.

### Safety choices kept small costs

Several faster experiments were rejected because they weakened safety. The
checked versions kept most of the gain.

| Choice                                               | Result                                           | Why                                                                                                 |
| ---------------------------------------------------- | ------------------------------------------------ | --------------------------------------------------------------------------------------------------- |
| checked descriptor cache instead of `unsafeDowncast` | steady turn fell from 2,198 to 1,337 ns          | the unsafe version saved only 5% and could turn an invariant failure into undefined behavior        |
| unchecked exclusivity on scalar columns only         | steady turn fell from 2,152 to 1,696 ns          | scalar storage is MainActor-only and trivial; user values keep checks because `deinit` can run code |
| scoped record borrows                                | steady ARC fell from 26/35 to 21/30 in the probe | the arena owns records for the whole synchronous walk                                               |
| inline `AnyHashable` keys                            | keyed references allocate nothing                | other layouts added a global table, slower calls, or more public overloads                          |

The checked descriptor cache uses a never-reused context ID, not a memory
address, and validates the slot generation before reuse. Those checks prevent
ABA and stale-slot bugs.

The scalar exclusivity change also moved one-key turns from 2,861 to 2,390 ns
and 1,000-key turns from 2,902 to 2,441 ns. Typed value columns kept full
checks, giving up another measured 4.4% to preserve a clear trap.

Record borrowing had a larger effect on deep graphs. In the probe, a 100-node
walk fell from 729 to 524 retains and from 738 to 533 releases. The benchmark
then measured 22 retains, 28 releases, zero mallocs, and 676 ns for a steady
turn in E11. A smaller `unowned(unsafe)` field-only experiment changed no
totals and was reverted.

## 4. What still needs work

### Keyed turns are the clearest target

Keyed turns take 2.18× as long as keyless turns in E13. About 195 ns of the
685 ns gap belongs to the public `AnyHashable` representation. The remaining
roughly 490 ns includes repeated metadata, witness lookup, hashing, and an
uncached protocol-conformance path. A specialized keyed frontier is the most
promising untested route.

### Cold start needs a profile before a fix

Cog starts Storefront in 19 ms, compared with 5,865 µs for the memo port. The
Cog-only footprint build takes 3,033 µs. The rest has not been split among
first settlement, async scheduling, and fixture work. A phase-split profile is
required before changing cold code.

Some of this gap is structural. The memo port builds almost no dependency
graph. The exact 3.2× gap may still contain avoidable work, but current data
cannot say how much.

### ARC is lower, but not gone

The steady turn still retains 18 times and releases 25 times. An ARC-reduction
series cut it in three steps while preserving the zero-allocation gate:

| Point                       | retains | releases |    p50 | Environment                       |
| --------------------------- | ------: | -------: | -----: | --------------------------------- |
| before the series           |      30 |       37 | 756 ns | [E10](#benchmark-environment-e10) |
| thread slot, remove payload |      28 |       34 | 744 ns | [E10](#benchmark-environment-e10) |
| borrow descriptor records   |      22 |       28 | 676 ns | [E11](#benchmark-environment-e11) |
| trim two small sites        |      18 |       25 | 709 ns | [E12](#benchmark-environment-e12) |

Only the 744 to 676 ns drop is large enough to claim from this series. The
other time changes are session noise.

About five retain/release pairs remain per settled node in the deep probe.
Likely sites are recompute closure copies, typed-column value moves, and
`Reader` construction. The steady turn also retains some flush closures and
`Writer` or `Reader` fields. Apple's Observation registrar accounts for about
three pairs and is outside Cog's control.

### The last full profile is stale

The last full arena profile ran before the typed frontier and the ARC series
above. It is useful history, not a current list of percentages.

| Cost in that profile | share |
| -------------------- | ----: |
| exclusivity checks   | 31.7% |
| generic metadata     | 26.0% |
| Cog code             | 12.2% |
| value copies         |  8.2% |
| ARC                  |  6.5% |
| actor checks         |  2.2% |

That profile led to targeted scalar exclusivity changes, a checked location
cache, and then the typed frontier. Those changes make its shares stale. The
[repeatable call-site attribution probe](https://github.com/skeswa/cog/blob/main/swift/Benchmarks/probes/M9-01-call-site-attribution.md)
contains the full method and call-site record. Re-profile before optimizing
one of those old hot sites again.

### Missing evidence

- No current profile of the shipping core.
- No pinned-runner session behind the proposed Storefront thresholds.
- No compact Storefront artifact and no post-lift paired compact run.
- No neutral cross-runtime footprint cut.
- No UI app for the three comparison runtimes.
- No physical-device UI measurements.

## 5. Regression gates

`mise run bench:thresholds:check` enforces these rules on the pinned host. It
first runs an allocating witness so a broken counter cannot report a false
zero. `mise run bench:thresholds:sentinel` proves the gate rejects an
impossible limit.

- A keyless steady turn has exactly zero mallocs at p90.
- Settling one node has exactly zero mallocs.
- Building a keyed value reference has exactly zero mallocs.
- Writing one pinned key costs O(changed keys), not O(all pinned keys). At
  1,000 pinned keys, a turn may use at most 90 retains and 110 releases.
- With 1,000 states and 12 tracked reads, exactly 12 Observation boundary
  objects exist.
- A keyed steady turn has zero mallocs and no more than 30 retains and 38
  releases.

### Absolute graph limits

The `perf-10-*` limits are intentionally loose. They catch large regressions,
not small changes. They are about three times the slower p90 from E1.

| Runtime           | recorded p90: diamond / deep / broad / unstable | limits: diamond / deep / broad / unstable |
| ----------------- | ----------------------------------------------- | ----------------------------------------- |
| Cog               | 5.231 / 2.750 / 13 / 2.755 ms                   | 20 / 10 / 40 / 10 ms                      |
| raw `@Observable` | 0.820 / 0.216 / 2.277 / 0.350 ms                | 3 / 1 / 8 / 2 ms                          |
| swift-state-graph | 26 / 15 / 37 / 7.696 ms                         | 80 / 50 / 120 / 25 ms                     |

### Proposed Storefront gates

Two Cog-only cuts are good CI candidates:

- `perf-15-storefront-interactions`: exactly 12 mallocs at p90 and at most
  600 µs wall time. E14 measured 12 mallocs and 153 µs at p90.
- `perf-15-storefront-compute-control`: exactly 5,611 mallocs at p90 and at
  most 1.7 ms. E14 measured 5,611 mallocs and 481 µs at p90.

These gates are **not committed yet**. One paired run on the pinned runner must
confirm them first. Cold, session, footprint, and async cuts stay report-only
because they have low sample counts or scheduler-shaped variance. Cross-runtime
`perf-16` cuts also stay report-only because Cog does not control the tuning of
the other libraries. `bench:compact` has no thresholds.

## 6. Next measurements

| ID  | Next step                                                                                | Success looks like                                                  |
| --- | ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| F1  | Run Storefront on the pinned runner and repeat the UI suite.                             | The two proposed gates reproduce and can be committed.              |
| F2  | Profile cold start as build, first settlement, and teardown.                             | The unexplained part of the 19 ms cold start has named call sites.  |
| F3  | Measure a compact Storefront artifact and rerun both arena modes after the runtime lift. | The size table and current compact ratio are complete.              |
| F4  | Repeat the three-runtime graph comparison on pinned Xcode and qualify release archives.  | Comparative results reproduce on the release toolchain.             |
| F5  | Add a neutral “demand roots only” runtime operation.                                     | A fair cross-runtime footprint cut can run.                         |
| F6  | Test a specialized keyed frontier and narrower internal key handling.                    | The keyed/keyless ratio falls below 2.18× without changing the API. |
| F7  | Reduce remaining `Reader`, closure, and typed-column ARC work.                           | Steady and deep ARC counts fall while zero-allocation gates hold.   |
| F8  | Re-profile the shipping core.                                                            | Current hot sites replace the stale percentages above.              |
| F9  | Optimize cold construction after F2.                                                     | Storefront cold and session times fall without weaker behavior.     |

## Measurement environments

All measurements used optimized release builds and benchmark harness 1.36.2.
“Not a release check” means a session did not qualify a release candidate on
the pinned runner.

E3 and E5 through E12 used `mactop`: Apple M4 Pro arm64, 12 cores, 24 GB,
macOS 26.4.1, Xcode 26.4 (17E192), and Swift 6.3. E1 and E2 recorded the same
host name and hardware size, but only identified the chip as Apple Silicon.
E13 and E14 used `koomac`: Apple M5 Pro arm64, 5 performance cores, 10
efficiency cores, 48 GB, macOS 26.5.1 (Darwin 25.5.0), Xcode 26.6 (17F113),
Swift 6.3.3, and malloc interposer 1.4.0. UI session details are in their rows.

| ID                                        | Date       | Run                                | Notes                                                                                                                                                                                                                                                                        |
| ----------------------------------------- | ---------- | ---------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| <a id="benchmark-environment-e1"></a>E1   | 2026-08-17 | initial baseline                   | `mactop`; Darwin 25.4.0; Swift 6.3.0                                                                                                                                                                                                                                         |
| <a id="benchmark-environment-e2"></a>E2   | 2026-08-19 | shared-runtime run                 | `mactop`; Apple Swift 6.3                                                                                                                                                                                                                                                    |
| <a id="benchmark-environment-e3"></a>E3   | 2026-08-20 | corrected Storefront run           | `mactop`; both cores ran back to back on an idle host                                                                                                                                                                                                                        |
| <a id="benchmark-environment-e4"></a>E4   | 2026-08-19 | Storefront UI smoke                | `mactop`; iPhone 17 Pro simulator, iOS 26.4 (23E244), smoke profile                                                                                                                                                                                                          |
| <a id="benchmark-environment-e5"></a>E5   | 2026-08-21 | specialization run                 | `mactop`; seven paired PERF-03 runs and three warm sweeps; not a release check                                                                                                                                                                                               |
| <a id="benchmark-environment-e6"></a>E6   | 2026-08-21 | three-core comparison              | `mactop`; simple, unspecialized arena, and specialized arena ran back to back; not a release check                                                                                                                                                                           |
| <a id="benchmark-environment-e7"></a>E7   | 2026-08-23 | paired Storefront arena modes      | `mactop`; both modes ran back to back after 12 Storefront tests passed; not a release check                                                                                                                                                                                  |
| <a id="benchmark-environment-e8"></a>E8   | 2026-08-23 | corrected Storefront UI run        | `mactop`; iPhone 17 Pro simulator, iOS 26.4 (23E244), release, smoke profile, five samples                                                                                                                                                                                   |
| <a id="benchmark-environment-e9"></a>E9   | 2026-08-23 | current graph runtime comparison   | `mactop`; all twelve `perf-10-*` cuts in one idle session; swift-state-graph 0.28.0; not a release check                                                                                                                                                                     |
| <a id="benchmark-environment-e10"></a>E10 | 2026-08-23 | turn-machinery ARC run             | `mactop`; 3,908 steady-turn samples after the thread-slot cut; exact counters; not a release check                                                                                                                                                                           |
| <a id="benchmark-environment-e11"></a>E11 | 2026-08-23 | record-borrow run                  | `mactop`; 4,177 steady-turn samples after the record borrows; exact counters; not a release check                                                                                                                                                                            |
| <a id="benchmark-environment-e12"></a>E12 | 2026-08-23 | small-site run                     | `mactop`; 4,104 steady-turn samples after the small-site trims; exact counters; not a release check                                                                                                                                                                          |
| <a id="benchmark-environment-e13"></a>E13 | 2026-08-24 | keyed-turn comparison              | `koomac`; keyless and keyed steady turns in one idle session, plus probe attribution and six-second samples; CI toolchain, non-CI host; not a release check                                                                                                                  |
| <a id="benchmark-environment-e14"></a>E14 | 2026-08-25 | four-runtime Storefront comparison | `koomac`; 22 `perf-15` and `perf-16` cuts from 16:27:11Z to 16:29:36Z; all Storefront suites green first; swift-state-graph 0.28.0 at `e602fcdb19342a38c135543e7228b3fd60753dc7`; CI toolchain, non-CI host; uncommitted runtime-lift work on `8f3f70e`; not a release check |

The call-site attribution and ARC-series profiler probes have no environment
ID. They used `mactop`,
release builds with debug symbols, and the same Xcode 26.4 toolchain described
above. Do not compare their absolute values with an E-numbered session.

### Measurement rules

- Allocation and ARC counters are process-wide. Use them only while the graph
  is quiet, with no async completion or teardown inside the timer.
- `mallocFreeDelta` is allocations minus frees during the timed region.
  `memoryLeakedBytes` is the matching requested-byte balance. Neither is a
  full live-heap count.
- Resident memory is page-sized and sampled. Use it for large changes only.
- Every sample checks its result and run count. Storefront also checks a shadow
  digest after timing.
- A zero-allocation gate must run `perf-witness-allocating` first.
- Compare runtimes only within one session. Do not subtract a result from one
  environment from a result in another.
