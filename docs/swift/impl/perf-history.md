# Cog for Swift: performance history

_August 23, 2026_

This file tells the story of how Cog got fast. It keeps the old numbers, the
retired comparisons, and the decisions they settled, so that
[benchmarks.md](./benchmarks.md) can stay focused on the current build.

Nothing here is current evidence. If a number in this file disagrees with one
in benchmarks.md, benchmarks.md wins. Environment IDs such as
[E1](./benchmarks.md#benchmark-environment-e1) point at the environment table
in benchmarks.md.

## The short version

Cog's first runtime was a class-based core we called **simple**. Each piece of
state was an object with pointers to its neighbors. It was easy to verify, and
M5 gave it a full benchmark baseline.

M6 built a second runtime, the **arena**, which stores state in columns and
edges in a shared pool. The first face-off was a split decision: the arena won
wide graphs but lost the smallest turn and had a worse pinned-key slope. So the
simple core stayed the default, and the planned 0.2.0 release did not happen.

M9 changed the picture in three steps. First, shared machinery that both cores
paid for was fixed: a steady turn stopped allocating, and boundary notices
stopped costing time per pinned key. Second, profiling found why the arena
still lost on cold construction: its generic storage boundary made every keyed
access run unspecialized generic code. Third, the fix for that, a typed
frontier of `@inlinable` entry points, made the **specialized arena** faster
than everything else on every shape measured. It shipped as the only core in
0.5.0. `CompactArena` remains as an opt-out that turns the typed frontier off
to keep the binary smaller.

Along the way, a review found five bugs in the first Storefront harness. All of
its early results were thrown out and remeasured.

## The simple core's baselines

The [initial baseline (E1)](./benchmarks.md#benchmark-environment-e1) covered
`M5-06` and `M5-07a` on the simple core.

| Operation                |   mallocs |   objects |  retains |  releases |
| ------------------------ | --------: | --------: | -------: | --------: |
| keyed reference creation |         0 |         0 |        — |         — |
| steady turn              |         7 |         7 |    65–66 |     92–93 |
| 16-consumer fan          |        26 |        26 |    1,116 |     2,032 |
| added cost per consumer  | about 1.3 | about 1.3 | about 70 | about 129 |

`M5-07b` measured 1,000 simple states at about 1.4 KB each, sampled in whole
pages. `M5-07d` measured the old pinned-key slope, which grew with every
pinned key even when nothing changed:

| Pinned keys | retains | releases | p50 time |
| ----------: | ------: | -------: | -------: |
|           1 |      68 |       95 |   2.7 µs |
|         100 |     167 |      194 |   4.8 µs |
|         500 |     567 |      594 |    14 µs |

`M9-06` later removed this slope on both cores. The current flat cost and its
gate are in benchmarks.md.

## Storage layout selections

Two representation choices were measured in
[E1](./benchmarks.md#benchmark-environment-e1) and then settled. The rejected
layouts were deleted from the codebase. Their numbers stay here so the choices
can be audited without keeping three implementations alive.

### Value references

`M5-09e` used 100 keys, five arms, and 500 turns. The churn test keeps 10 live
keys while creating 510.

| Layout               | reference size | keyed diamond p50 |   key churn p50 | peak memory, diamond / churn |
| -------------------- | -------------: | ----------------: | --------------: | ---------------------------: |
| inline `AnyHashable` |       48 bytes |   1,547 M / 78 ms | 1,536 M / 94 ms |                  121 / 15 MB |
| interned token       |       17 bytes |   1,506 M / 77 ms | 1,512 M / 98 ms |                  119 / 15 MB |
| generic keyed        |       16 bytes |   1,640 M / 83 ms | 1,540 M / 95 ms |                  121 / 15 MB |

Inline `AnyHashable` won. It builds a keyed reference with zero allocations
and no global table. Interned tokens are smaller but their table never shrinks
and each new key takes a lock. Generic references would have added public
overloads and ran about 6% slower on the diamond.

### Arena edges

For `M6-05c`, each root read one stable control and 32 data sources. The churn
test replaces the 32 data edges each turn.

| Layout               | mostly static, p50 | high churn, p50 | mallocs / objects | static retains / releases | churn retains / releases |
| -------------------- | -----------------: | --------------: | ----------------: | ------------------------: | -----------------------: |
| shared linked pool   |      294 K / 12 µs |   335 K / 13 µs |             7 / 7 |                 233 / 256 |                228 / 251 |
| prefix arrays        |      303 K / 12 µs |   321 K / 13 µs |             7 / 7 |                 233 / 256 |                229 / 252 |
| inline plus overflow |      304 K / 12 µs |   326 K / 13 µs |             7 / 7 |                 233 / 256 |                228 / 251 |

The shared linked pool won on the common, mostly static shape by about 3% of
instructions. All three tied on time and allocations. Prefix arrays won only
the forced-churn instruction count and added ARC work.

## The first core decision

In [E1](./benchmarks.md#benchmark-environment-e1), `M6-12a` ran the same 248
public scenarios on both cores and compared them.

| Workload        | Core   | mallocs / objects | retains / releases | p50 time |
| --------------- | ------ | ----------------: | -----------------: | -------: |
| steady turn     | simple |             7 / 7 |            66 / 93 | 2.202 µs |
| steady turn     | arena  |             5 / 5 |            48 / 67 | 2.425 µs |
| 16-consumer fan | simple |           26 / 26 |      1,132 / 2,048 |    40 µs |
| 16-consumer fan | arena  |             5 / 5 |          424 / 488 |    21 µs |

The arena cut wide-graph work in half but still allocated, lost the smallest
turn, and had a worse pinned-key slope past 100 keys. The simple core stayed
the default. The arena was kept for research, and no 0.2.0 release was made.

## Shared runtime work in M9

The [shared-runtime run (E2)](./benchmarks.md#benchmark-environment-e2)
measured fixes that helped both cores.

`M9-10` made the steady turn allocate nothing:

| Metric             | before M9 | after M9 |
| ------------------ | --------: | -------: |
| `mallocCountTotal` |         7 |    **0** |
| retains            |        66 |       63 |
| p50 time           |  2.202 µs | 1.676 µs |

Zero held at every percentile across 1,751 samples. `M9-15` did the same for
settling a node: pulling one source through 100 automatic nodes went from 107
allocations to zero. The problem was a dependency list copied before reuse.

`M9-06` made boundary notices cost O(changed keys) instead of O(pinned keys).
One changed key cost the same with 1 pinned neighbor as with 1,000: on the
simple core, 71 retains and about 2.4 µs either way.

`M9-17` then compared the cores again. The arena won broad and unstable graphs
but still lost the smallest turn and the deep chain:

| Workload | simple p50 | arena p50 | simple instructions | arena instructions |
| -------- | ---------: | --------: | ------------------: | -----------------: |
| diamond  |   4,551 µs |  4,219 µs |                84 M |              102 M |
| deep     |   2,279 µs |  2,724 µs |                43 M |               68 M |
| broad    |      12 ms |   9.08 ms |               221 M |              217 M |
| unstable |   2,410 µs |  1,248 µs |                43 M |               31 M |

## The construction gap and the typed frontier

The arena took 2.2× as long as simple to build a 1,000-state keyed graph.
`M9-25` and `M9-26` chased that gap with paired counters and a CPU profile.
Allocation counts could not explain it. The profile could:

| CPU bucket                        | simple share | arena share | arena cost vs simple |
| --------------------------------- | -----------: | ----------: | -------------------: |
| generic metadata + witness tables |        17.7% |       28.6% |                ~3.5× |
| unspecialized generic value work  |        25.7% |       30.5% |                ~2.6× |
| array growth and copying          |         1.5% |        6.8% |                 ~10× |
| ARC                               |        13.0% |        3.3% |               ~0.55× |

A simple state is one concrete object with inline fields. An arena state is
split across scalar columns and a generic value column stored as `AnyObject`.
Every keyed access had to restore the concrete type and run unspecialized
generic code.

The fix was a typed frontier: the arena's public generic reads,
descriptor-and-key resolution, and typed value-column operations ship as
stable `@inlinable` bodies, so client builds specialize them. The
[specialization run (E5)](./benchmarks.md#benchmark-environment-e5) measured
the result on the 500-source, 500-consumer build:

| Measure                        | arena without frontier | specialized arena | change |
| ------------------------------ | ---------------------: | ----------------: | -----: |
| paired-run median of p50s      |               2,163 µs |          1,102 µs | -49.1% |
| paired-run median instructions |                   55 M |              27 M |   -51% |
| standalone probe allocations   |                  5,697 |             1,699 | -70.2% |

That put arena construction within 3% of simple. The warm sweeps in the same
run cut the steady turn to 909 ns and the 100-node chain to 64 µs.

An earlier rule had rejected specialization because it grew the binary more
than 5%. After these results, about 80% of surveyed users said they would take
the size cost for the speed, so the frontier became the default and the
`CompactArena` trait became the opt-out. The measured size cost and the
current compact-versus-default numbers are in benchmarks.md.

## Retiring the simple core

Two runs closed the case. The
[three-core comparison (E6)](./benchmarks.md#benchmark-environment-e6) ran
simple, the arena without the frontier, and the specialized arena back to
back:

| Shape    | simple p50 | arena p50 | specialized p50 | specialized vs. simple |
| -------- | ---------: | --------: | --------------: | ---------------------: |
| diamond  |   5.112 ms |  2.918 ms |        1.859 ms |             64% faster |
| deep     |   2.511 ms |  2.009 ms |        0.907 ms |             64% faster |
| broad    |      13 ms |  7.909 ms |        4.313 ms |             67% faster |
| unstable |   2.693 ms |  0.787 ms |        0.559 ms |             79% faster |

The [corrected Storefront run (E3)](./benchmarks.md#benchmark-environment-e3)
showed the same thing on an application-shaped graph. The arena (without the
frontier) beat simple by 12.5× to 66× on every graph-backed cut:

| Cut                                  | simple p50 | arena p50 | arena result     |
| ------------------------------------ | ---------: | --------: | ---------------- |
| `perf-15-storefront-cold`            |     442 ms |     34 ms | **13× faster**   |
| `perf-15-storefront-session`         |   3,915 ms |    178 ms | **22× faster**   |
| `perf-15-storefront-interactions`    |   6,296 µs |    201 µs | **31× faster**   |
| `perf-15-storefront-async-burst`     |      51 ms |   4.09 ms | **12.5× faster** |
| `perf-15-storefront-footprint`       |     481 ms |   7.29 ms | **66× faster**   |
| `perf-15-storefront-compute-control` |     565 µs |    545 µs | no clear change  |

The control holds no graph and barely moved, which is what makes the other
rows meaningful. The simple core's big loss had one main cause: on every
dependency read, its `addSubscriber` scanned the producer's whole subscriber
list twice, once to drop dead weak edges and once to find the consumer. With
1,200 consumers on one shared producer, that is about 1.44 million weak-edge
checks. The arena links an integer edge in O(1) and loads no weak references.

The ARC counters told the same story. A steady Storefront interaction used 53×
as many retains and 145× as many releases on simple as on the arena. The
2,402-state footprint kept 18,054 surviving allocations on simple against 75
on the arena, while holding 28% more bytes.

After the specialized arena also won the warm and whole-graph shapes, `M9-18`
recorded the decision: the specialized arena is the only shipping core, and
the simple core was deleted. The retired selectors are manifest errors now, so
none of these comparisons can be rerun.

## The external runtime comparison

In [E1](./benchmarks.md#benchmark-environment-e1), `M6-11c` compared the two
Cog cores of that time with swift-state-graph 0.28.0 and raw `@Observable`.
Each cell shows instructions and median time.

| Runtime                |      diamond p50 |           deep p50 |        broad p50 |       unstable p50 |
| ---------------------- | ---------------: | -----------------: | ---------------: | -----------------: |
| simple Cog             |  99 M / 4.964 ms |    51 M / 2.540 ms |    239 M / 12 ms |    45 M / 2.484 ms |
| arena Cog              | 103 M / 4.362 ms |    68 M / 2.654 ms | 214 M / 8.905 ms |    31 M / 1.272 ms |
| swift-state-graph 0.28 |    506 M / 25 ms |      301 M / 14 ms |    715 M / 36 ms |   152 M / 7.479 ms |
| raw `@Observable`      |  16 M / 0.787 ms | 4.106 M / 0.205 ms |  45 M / 2.130 ms | 7.094 M / 0.327 ms |

Raw Observation has no automatic-value cache, so it is a lower bound rather
than a competitor. It was fastest on all four shapes. swift-state-graph was
slowest on all four. The absolute CI limits in benchmarks.md still come from
this session; the current three-runtime comparison against the shipping core
is in benchmarks.md.

## The Storefront correction

On August 20, 2026, a review found five bugs in the first Storefront harness:

- It timed shadow-model setup and checks that were not part of Cog.
- Its async drain could finish before all graph tasks started.
- Later interaction samples became no-op writes.
- Pricing stages read inputs they did not use.
- The control used list prices instead of running the pricing chain.

Every early Storefront result, headless and UI, was withdrawn. The corrected
headless run (E3, above) replaced the headless numbers, the
[paired arena-configuration run (E7)](./benchmarks.md#benchmark-environment-e7)
measured the shipping default against `CompactArena`, and the
[corrected UI run (E8)](./benchmarks.md#benchmark-environment-e8) replaced the
UI numbers. The old footprint counts happened to match the corrected ones
because that region never ran the bad shadow checks.
