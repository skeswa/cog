# Cog for Swift: benchmark results

_August 21, 2026_

This document records benchmark results and the choices they support. It puts
current results first. Older results appear only when they explain a choice,
show progress, or record a withdrawn measurement.

The benchmark design is in [design/perf.md](../design/perf.md). Profiler results
and optimization details are in [optimization.md](./optimization.md). Commands,
tool versions, and threshold file formats are in the
[`swift/Benchmarks` README](https://github.com/skeswa/cog/blob/main/swift/Benchmarks/README.md).

In the tables below, p50 is the median and p90 is the 90th percentile. Lower
times, instruction counts, allocations, retains, and releases are better. ARC
means Swift's automatic reference-counting work.

## Current core decision

The **specialized arena** is the sole shipping core and default implementation.
It stores states in shared columns, edges in a shared pool, and exposes a stable
typed frontier so client compilation can specialize Cog's generic value work.
The former **simple core** is retired. Applications that prioritize binary size
can explicitly suppress the typed frontier with the non-default `CompactArena`
package trait. That public trait is also the supported way to benchmark the
compact arena configuration.

Current evidence explains the default and its opt-out:

- The unspecialized arena is 18% faster than simple on a steady turn and 27%
  faster on a 100-node chain.
- In E5 scouting, the specialized arena extends those wins to 45% and 50%
  against the earlier E2 simple results; it is 32% faster than the earlier
  unspecialized-arena result on both shapes. These were separate sessions, not
  a paired three-way run.
- In the back-to-back E6 whole-graph run, specialized arena was 64% to 79%
  faster than simple and 29% to 55% faster than unspecialized arena across the
  diamond, deep, broad, and unstable shapes.
- Unspecialized arena is 12.5× to 66× faster than simple on every graph-backed
  Storefront cut. The specialized Storefront executable has a size result but
  no corrected headless timing yet.
- Unspecialized arena uses 28% fewer bytes for Storefront's 2,402-state graph.
- Unspecialized arena loses the pinned-key turn by about 15%; specialization
  reduces the scouting result to about 2.4 µs, near the simple result.
- Unspecialized arena takes 2.2× as long as simple to build a 1,000-state keyed
  graph. Specialization closes that gap to about 3%.

These results selected specialized arena on runtime evidence; stakeholder
research changed the product weighting after about 80% of users said they would
accept its binary-size cost for the speed and overhead gains. The default now
serves that majority. `CompactArena` preserves an explicit application-level
escape hatch for the remaining size-sensitive users without restoring the
simple implementation. Pinned-host Storefront and UI follow-up remains owed for
release qualification, not for reopening the core choice.

### Warm execution

`M9-23`, environment E2, supplies the historical simple and
unspecialized-arena columns.
Work after `M9-17` removed the arena's main exclusivity and metadata costs. The
specialized-arena column is the median of three independently recorded p50s in
environment E5. It is scouting across the same host and toolchain, not a
paired three-way release qualification.

| Shape                 |   simple | arena, unspecialized | arena, specialized | specialized result                      |
| --------------------- | -------: | -------------------: | -----------------: | --------------------------------------- |
| steady turn, p50      | 1,639 ns |             1,337 ns |             909 ns | 45% vs. simple; 32% vs. arena           |
| steady turn, retains  |       62 |                   38 |                 31 | lowest                                  |
| 16-consumer fan, p50  |    37 µs |                13 µs |             7.6 µs | 4.9× vs. simple; 41% faster than arena  |
| 100-node chain, p50   |   128 µs |                94 µs |              64 µs | 50% vs. simple; 32% vs. arena           |
| pinned-key turn, p50  |  ~2.2 µs |              ~2.6 µs |            ~2.4 µs | near simple; about 8% faster than arena |
| allocations, all four |        0 |                    0 |                  0 | tie                                     |

The warm gap is a storage cost, not an allocation cost. The simple core keeps
each state in a class. Its forward edges hold `any CogState` references, and
its reverse edges are weak-reference objects. A graph walk therefore pays for
ARC, weak loads, actor checks, and existential access at each step. In the
`M9-21` profile, ARC was 28.5% of the simple turn against 6.5% of the arena
turn; actor checks were 8.9% against 2.2%. The arena instead walks integer rows
and scalar edges, and it updates a matching edge in place.

### Whole-graph propagation

PERF-10, environment E6. Historical simple, unspecialized arena, and specialized
arena ran back to back in that order on the same host. Each benchmark performs
its own warmup and gathers samples for up to three seconds. This closes the
stale `M9-17` comparison and supplies the evidence for retiring simple, but
remains scouting because Xcode 26.4 is not the repository's pinned Xcode 26.6
release environment.

| Shape    | simple p50 | arena p50 | specialized p50 | specialized vs. simple | specialized vs. arena | samples, simple / arena / specialized |
| -------- | ---------: | --------: | --------------: | ---------------------: | --------------------: | ------------------------------------: |
| diamond  |   5.112 ms |  2.918 ms |        1.859 ms |             64% faster |            36% faster |                     398 / 971 / 1,603 |
| deep     |   2.511 ms |  2.009 ms |        0.907 ms |             64% faster |            55% faster |                   833 / 1,390 / 3,245 |
| broad    |      13 ms |  7.909 ms |        4.313 ms |             67% faster |            45% faster |                       212 / 304 / 693 |
| unstable |   2.693 ms |  0.787 ms |        0.559 ms |             79% faster |            29% faster |                 1,044 / 3,611 / 5,214 |

The instruction counter moved in the same direction and is less sensitive to
host scheduling than wall clock:

| Shape    | simple instructions | arena instructions | specialized instructions | specialized vs. simple | specialized vs. arena |
| -------- | ------------------: | -----------------: | -----------------------: | ---------------------: | --------------------: |
| diamond  |                84 M |               65 M |                     41 M |              51% fewer |             37% fewer |
| deep     |                43 M |               47 M |                     21 M |              51% fewer |             55% fewer |
| broad    |               221 M |              166 M |                     92 M |              58% fewer |             45% fewer |
| unstable |                43 M |               18 M |                     13 M |              70% fewer |             28% fewer |

The unspecialized arena still used 9% more instructions than simple on deep,
despite finishing 20% sooner. Specialization removes that last whole-graph
instruction loss. Process-level resident peak remained 14–15 MB and did not
separate the configurations.

### Graph construction

`M9-25`, environment E2. Each measured region built and settled a graph with
500 keyed sources and 500 keyed consumers. Seven paired runs were taken. The
specialized results are medians from the seven paired baseline/frontier runs in
E5. The benchmark released the context after `stopMeasurement()`, so teardown
is not part of these results.

| Measure                    |    simple | arena, unspecialized | arena, specialized | specialized result                           |
| -------------------------- | --------: | -------------------: | -----------------: | -------------------------------------------- |
| build + settle, p50        | ~1,068 µs |            ~2,320 µs |           1,102 µs | 3% slower than simple; 52% faster than arena |
| resident-memory delta, p50 | ~1,345 KB |            ~1,541 KB |           1,508 KB | no clear winner                              |

The memory ranges overlapped: 1,279–1,656 KB for simple, 1,082–1,918 KB for
unspecialized arena, and 1,049–1,689 KB for specialized arena. Resident memory
is sampled in whole pages, so this test cannot separate the cores. Storefront's
counted footprint test gives a clearer result.

`M9-26` added a standalone profile of the same graph shape. Its context was
local, so this profile included teardown even though the benchmark above did
not. E5 repeated the allocation counter after specialization; that probe did
not capture retains or releases.

| Counter     | simple | arena, unspecialized | arena, specialized |
| ----------- | -----: | -------------------: | -----------------: |
| allocations |  4,525 |                5,697 |              1,699 |
| retains     | 22,504 |               17,527 |       not captured |
| releases    | 38,052 |               24,745 |       not captured |

The arena allocated 26% more, but that is too small to explain a 2.2× time
gap. It also did less ARC work. The CPU profile found the missing cost:

| CPU bucket                          | simple share | arena share | absolute arena/simple cost |
| ----------------------------------- | -----------: | ----------: | -------------------------: |
| generic metadata + witness tables   |        17.7% |       28.6% |                      ~3.5× |
| unspecialized generic value work    |        25.7% |       30.5% |                      ~2.6× |
| array growth and copying            |         1.5% |        6.8% |                       ~10× |
| dictionaries and `AnyHashable` keys |        12.2% |        9.3% |                      ~1.7× |
| ARC                                 |        13.0% |        3.3% |                     ~0.55× |
| dynamic casts and lookup            |        10.9% |        3.1% |                     ~0.63× |

The primary cause is the arena's erased generic storage boundary. A simple
state is one concrete object with inline fields. An arena state is split across
scalar columns and a generic `CogArenaValueColumn<Value>` stored as `AnyObject`.
Each keyed access restores the concrete column and runs unspecialized generic
array code. New rows also grow nine scalar columns and two typed value arrays.

`M9-23` avoids most lookup and metadata work for keyless state by memoizing its
slot and column. This test is fully keyed, so it always takes the uncached path.
E5 validates the typed frontier as the fix: it cut the paired median time by
49.1%, instructions by about 51%, and standalone allocations by 70.2%.

The diagnosis is validated, but the exact share of the original 2.2× gap
remains approximate because `M9-25` and `M9-26` used different teardown
boundaries. There is no evidence that arena teardown itself was 2.2× slower.

### Default arena specialization and compact opt-out

Typed-frontier experiment, environment E5. By default, the arena's public
generic reads, descriptor-and-key resolution, record-closure formation, and
typed value-column operations ship as stable `@inlinable` bodies. The
`CompactArena` trait suppresses those annotations while the scalar graph
machinery remains opaque in both configurations. Seven paired PERF-03 runs used
identical build-and-settle boundaries:

| Measure                        | arena baseline | specialized arena | change         |
| ------------------------------ | -------------: | ----------------: | -------------- |
| paired-run median of p50s      |       2,163 µs |          1,102 µs | **-49.1%**     |
| paired-run median instructions |           55 M |              27 M | **about -51%** |
| standalone probe allocations   |          5,697 |             1,699 | **-70.2%**     |

The temporary exported-specialization control arm measured about 1.20 ms and
26–27 million instructions, so the stable frontier reached the intended
ceiling. The generic entry points remain as behavior-identical fallbacks.

The original 5% cost gate rejected making this universal. The later stakeholder
decision accepts the measured cost by default and retains the compact trait as
the opt-out. Retained clean release artifacts measured the final executable's
arm64 Mach-O `__TEXT` segment and its `__text` machine-code section:

| Artifact and comparison                      | baseline bytes | specialized arena bytes | absolute growth | relative growth |
| -------------------------------------------- | -------------: | ----------------------: | --------------: | --------------: |
| `CogGraph` `__TEXT`, vs. unspecialized arena |      2,506,752 |               2,670,592 |        +163,840 |           +6.5% |
| Storefront `__TEXT`, vs. historical simple   |        827,392 |                 991,232 |        +163,840 |          +19.8% |
| Storefront `__text`, vs. historical simple   |        688,821 |                 838,229 |        +149,408 |          +21.7% |

These percentages describe the complete executable segment or section, not a
standalone Cog library and not the app bundle or compressed download. The
absolute increase comes from the linked arena implementation and specialized
copies at Cog's generic value and key call sites. It can grow with the number
and type diversity of those compile-time call sites, but not with the number of
runtime state instances and not proportionally with unrelated application
code. Unrelated machine code enlarges the `__TEXT` denominator, reducing the
percentage; assets generally live outside `__TEXT`. `CompactArena` exists for
applications whose size budget outweighs the measured runtime gains.

The experiment ran on E5 rather than the repository's Xcode 26.6 release pin;
the recorded numbers establish the direction and the product trade, while the
pinned runner still owns release qualification.

### Evidence needed for the next decision

1. Repeat the corrected Storefront run in the pinned CI environment.
2. Rerun the Storefront UI suite. Its old results are withdrawn.
3. Repeat E6's three-way PERF-10 run on the pinned Xcode to qualify the scouting
   result.
4. Qualify both the specialized default and `CompactArena` release archives on
   the pinned Xcode.
5. Measure build, first settlement, and teardown as separate phases under the
   same profiler boundary.

## Measurement environments

All benchmark runs used release builds.

| ID  | Date       | Environment                                                                                                                                                                                                                            |
| --- | ---------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| E1  | 2026-08-17 | `mactop`, Apple Silicon arm64, 12 cores, 24 GB, macOS 26.4.1 / Darwin 25.4.0, Xcode 26.4 (17E192), Swift 6.3.0, harness 1.36.2                                                                                                         |
| E2  | 2026-08-19 | `mactop`, Apple Silicon arm64, 12 cores, 24 GB, macOS 26.4.1 / Darwin 25.4.0, Xcode 26.4 (17E192), Apple Swift 6.3, harness 1.36.2                                                                                                     |
| E3  | 2026-08-20 | `mactop`, Apple M4 Pro arm64, 12 cores, 24 GB, Xcode 26.4 (17E192), Apple Swift 6.3, harness 1.36.2; both cores run back to back on an idle host                                                                                       |
| E4  | 2026-08-19 | `mactop`, Xcode 26.4 (17E192), iPhone 17 Pro simulator on iOS 26.4 (23E244), arm64, Storefront smoke profile                                                                                                                           |
| E5  | 2026-08-21 | `mactop`, Apple M4 Pro arm64, 12 cores, 24 GB, macOS 26.4.1, Xcode 26.4 (17E192), Apple Swift 6.3, harness 1.36.2; seven paired PERF-03 runs and three specialized warm sweeps; scouting because the pinned Xcode 26.6 was unavailable |
| E6  | 2026-08-21 | `mactop`, Apple M4 Pro arm64, 12 cores, 24 GB, macOS 26.4.1 / Darwin 25.4.0, Xcode 26.4 (17E192), Apple Swift 6.3, harness 1.36.2; PERF-10 Cog shapes run back to back as simple, unspecialized arena, then specialized arena          |

Runs with malloc and ARC counters used the malloc interposer. The edge-layout
run used interposer 1.4.0. The external runtime comparison used
swift-state-graph 0.28.0 at revision
`e602fcdb19342a38c135543e7228b3fd60753dc7` and SwiftSyntax 603.0.2.

## Selected storage layouts

### Value references

`M5-09e`, environment E1. The keyed diamond uses 100 keys, five arms, and 500
turns. The churn test keeps 10 live keys while creating 510 keys. Workload cells
show instructions and time.

| Layout               | reference size | keyed diamond p50 |   key churn p50 | peak memory, diamond / churn |
| -------------------- | -------------: | ----------------: | --------------: | ---------------------------: |
| inline `AnyHashable` |       48 bytes |   1,547 M / 78 ms | 1,536 M / 94 ms |                  121 / 15 MB |
| interned token       |       17 bytes |   1,506 M / 77 ms | 1,512 M / 98 ms |                  119 / 15 MB |
| generic keyed        |       16 bytes |   1,640 M / 83 ms | 1,540 M / 95 ms |                  121 / 15 MB |

**Selected: inline `AnyHashable`.** It creates a keyed reference with zero
allocations and adds no global storage. Interned tokens are smaller, but their
table never shrinks and each new key takes a lock. Generic references would add
public overloads and were about 6% slower on the diamond.

The two rejected layouts were removed after the comparison. Their measured
results remain here so the choice can be audited without keeping permanent
conditional API and storage paths.

### Arena edges

`M6-05c`, environment E1. Each root reads one stable control and 32 data
sources. The static test keeps all edges. The churn test replaces the 32 data
edges each turn. Workload cells show instructions and time.

| Layout               | mostly static, p50 | high churn, p50 | mallocs / objects | static retains / releases | churn retains / releases |
| -------------------- | -----------------: | --------------: | ----------------: | ------------------------: | -----------------------: |
| shared linked pool   |      294 K / 12 µs |   335 K / 13 µs |             7 / 7 |                 233 / 256 |                228 / 251 |
| prefix arrays        |      303 K / 12 µs |   321 K / 13 µs |             7 / 7 |                 233 / 256 |                229 / 252 |
| inline plus overflow |      304 K / 12 µs |   326 K / 13 µs |             7 / 7 |                 233 / 256 |                228 / 251 |

**Selected: shared linked pool.** It used about 3% fewer instructions on the
normal, mostly static shape. All layouts had the same median time and allocation
count. Prefix arrays won only the forced-churn instruction count and added ARC
work. Inline plus overflow won neither test.

The two rejected layouts were removed after the comparison. Their measured
results remain here so the selected storage can be understood without keeping
three propagation implementations in production source.

## Current cost checks

### Pinned keys now cost O(changed keys)

`M9-06`, environment E2. One keyed source changes. All other keyed states stay
pinned and untouched.

| Pinned keys | simple retains / releases / p50 | arena retains / releases / p50 |
| ----------: | ------------------------------: | -----------------------------: |
|           1 |              71 / 89 / 2.490 µs |             55 / 70 / 3.154 µs |
|       1,000 |              71 / 89 / 2.402 µs |             55 / 70 / 3.174 µs |

The cost is flat on both cores. Before M9, work grew with every pinned key. The
current gate allows at most 90,000 retains and 110,000 releases across 1,000
operations, or 90 and 110 per turn.

### A steady turn allocates nothing

`M9-10`, environment E2. This is the simple core's steady turn.

| Metric             | before M9 | after M9 |
| ------------------ | --------: | -------: |
| `mallocCountTotal` |         7 |    **0** |
| `objectAllocCount` |         7 |    **0** |
| retains            |        66 |       63 |
| releases           |        93 |       76 |
| p50 time           |  2.202 µs | 1.676 µs |

Zero held at every percentile across 1,751 samples. A turn with no read also
allocates nothing. The gate requires exact zero, not a tolerance around zero.
The latest steady time is 1.639 µs after later shared work.

ARC is not zero. The latest steady turn still uses 62 retains, and a fan or
chain uses much more. Issue #373 tracks that work.

### Settling a node allocates nothing

`M9-15`, environment E2. This pulls one source through 100 automatic nodes.

| Metric             | before M9 |    now | per node |
| ------------------ | --------: | -----: | -------: |
| `mallocCountTotal` |       107 |  **0** |        0 |
| `objectAllocCount` |       107 |  **0** |        0 |
| retains            |     4,176 |  3,964 |     39.6 |
| releases           |     4,902 |  4,577 |     45.8 |
| p50 time           |    124 µs | 130 µs |   1.3 µs |

The old and new time rows came from different probes, so they are not a speed
comparison. The exact allocation rows are comparable. The allocation problem
was a dependency list copied before reuse.

### Observation boundaries stay lazy

`M5-07c`, environment E1. A graph held 1,000 states. Only 12 values were read
through the tracked subscript.

| Metric                  | p0     | p100   | samples |
| ----------------------- | ------ | ------ | ------: |
| `observationBoundaries` | **12** | **12** |   2,160 |

The exact gate makes sure Cog creates boundaries only for observed values.

## Runtime comparison and CI gates

### Comparison with other runtimes

`M6-11c`, environment E1. These are older than the latest core work, but they
remain the recorded comparison with swift-state-graph and raw Observation.
The current Cog-only three-way comparison is under “Whole-graph propagation”
above. The external runtimes were not rerun in E6, so this table preserves the
older common-session comparison. Each cell shows instructions and median time.

| Runtime                |      diamond p50 |           deep p50 |        broad p50 |       unstable p50 |
| ---------------------- | ---------------: | -----------------: | ---------------: | -----------------: |
| simple Cog             |  99 M / 4.964 ms |    51 M / 2.540 ms |    239 M / 12 ms |    45 M / 2.484 ms |
| arena Cog              | 103 M / 4.362 ms |    68 M / 2.654 ms | 214 M / 8.905 ms |    31 M / 1.272 ms |
| swift-state-graph 0.28 |    506 M / 25 ms |      301 M / 14 ms |    715 M / 36 ms |   152 M / 7.479 ms |
| raw `@Observable`      |  16 M / 0.787 ms | 4.106 M / 0.205 ms |  45 M / 2.130 ms | 7.094 M / 0.327 ms |

Raw Observation is a lower bound because it has no automatic-value cache. It was
fastest in all four shapes. swift-state-graph was slowest in all four.

Process-level peak memory did not separate the runtimes:

| Runtime                | diamond memory / samples | deep memory / samples | broad memory / samples | unstable memory / samples |
| ---------------------- | -----------------------: | --------------------: | ---------------------: | ------------------------: |
| simple Cog             |              13 MB / 595 |         14 MB / 1,163 |            13 MB / 241 |             13 MB / 1,172 |
| arena Cog              |              13 MB / 684 |         14 MB / 1,122 |            14 MB / 336 |             13 MB / 2,328 |
| swift-state-graph 0.28 |              13 MB / 118 |           13 MB / 212 |             14 MB / 84 |               13 MB / 400 |
| raw `@Observable`      |            13 MB / 3,730 |        13 MB / 10,000 |          13 MB / 1,379 |             13 MB / 8,854 |

### Absolute CI limits

`M6-11d`, environment E1. CI checks p90 time. The limits are about three times
the slower recorded p90 in each cell. They catch large regressions without
choosing a core.

| Runtime           | recorded p90: diamond / deep / broad / unstable | limits: diamond / deep / broad / unstable |
| ----------------- | ----------------------------------------------- | ----------------------------------------- |
| Cog, either core  | 5.231 / 2.750 / 13 / 2.755 ms                   | **20 / 10 / 40 / 10 ms**                  |
| raw `@Observable` | 0.820 / 0.216 / 2.277 / 0.350 ms                | **3 / 1 / 8 / 2 ms**                      |
| swift-state-graph | 26 / 15 / 37 / 7.696 ms                         | **80 / 50 / 120 / 25 ms**                 |

`mise run bench:thresholds:check` checks these limits and the exact
zero-allocation rules. It first runs an allocating witness, so a broken counter
cannot report a false zero. The task always builds the shipping default; retired
representation selectors are manifest errors, and the separate
`bench:compact` task does not apply these thresholds. `mise run
bench:thresholds:sentinel` proves the gate rejects an impossible limit.

## Storefront macrobenchmark

Storefront combines many graph shapes in one commerce session. It runs through
the shared package both headlessly and through SwiftUI. It is a
**representative workload v1**, not a claim about an average app.

### Workload shape

`M10-01`. Tests check every value in these tables.

| Property                     | `smoke` | `standard` | `stress` |
| ---------------------------- | ------: | ---------: | -------: |
| products                     |     120 |  **1,200** |    6,000 |
| categories                   |       6 |     **24** |       48 |
| rows visited in one session  |      24 |    **120** |      400 |
| rows held at once            |      12 |     **30** |       40 |
| prefetch margin on each side |       4 |      **8** |       12 |
| pricing policies             |       4 |     **16** |       48 |

| Declaration kind | Count |
| ---------------- | ----: |
| `ManualCog`      |    12 |
| `ManualCogBox`   |     5 |
| `Cog`            |    18 |
| `CogBox`         |     8 |
| `AsyncCog`       |     7 |
| `AsyncCogBox`    |     3 |

The original plan named five keyless async cogs, but the required roots,
middle nodes, and deep quotes need seven. It also named four manual boxes. The
fifth box tracks inventory generation per product, which lets the test prove
that offscreen updates do no work.

The longest useful path is 23 nodes. The workload covers search over the full
catalog, keyed async state, a 16-stage pricing chain, multi-source writes, cart
totals, stale async results, replaced requests, and release after a grace
period.

It does not cover several screens alive at once, real network or disk work,
memory pressure, a full navigation history, or physical-device performance.

### Measurement correction

On August 20, 2026, a review found five problems in the first harness:

- It timed shadow-model setup and checks that were not part of Cog.
- Its async drain could finish before all graph tasks started.
- Later interaction samples became no-op writes.
- Pricing stages read inputs they did not use.
- The control used list prices for cart items instead of running pricing.

The fixes moved shadow work outside timing, added a scheduled-work ledger,
made every sample change state, narrowed pricing dependencies, and fixed the
control. All earlier Storefront headless and UI results are withdrawn. The
corrected headless results below replace them. The UI suite has not been rerun.

### Corrected headless results

`M10-05` and `M10-08`, environment E3, standard profile. Both cores ran back to
back. `mise run test:storefront` passed all 14 tests first. These results are
report-only because they come from one host and one session.

| Cut                                  | simple p50 | arena p50 | arena result     | simple instructions | arena instructions | samples, simple / arena |
| ------------------------------------ | ---------: | --------: | ---------------- | ------------------: | -----------------: | ----------------------: |
| `perf-15-storefront-cold`            |     442 ms |     34 ms | **13× faster**   |             6,702 M |              795 M |                 10 / 10 |
| `perf-15-storefront-session`         |   3,915 ms |    178 ms | **22× faster**   |                57 G |            3,796 M |                   3 / 3 |
| `perf-15-storefront-interactions`    |   6,296 µs |    201 µs | **31× faster**   |                96 M |             4.51 M |             415 / 2,537 |
| `perf-15-storefront-async-burst`     |      51 ms |   4.09 ms | **12.5× faster** |               805 M |               70 M |                 50 / 50 |
| `perf-15-storefront-footprint`       |     481 ms |   7.29 ms | **66× faster**   |             6,979 M |              172 M |                   3 / 3 |
| `perf-15-storefront-compute-control` |     565 µs |    545 µs | no clear change  |              12.9 M |             12.9 M |           4,820 / 5,098 |

The control holds no graph and barely moved. Every graph-backed cut favored the
arena by at least 12.5×. Two selectors each read about 1,200 keyed values, but
the largest simple-core cost runs in the other direction: thousands of keyed
states also read the same keyless producers.

On every dependency read, the simple core's `addSubscriber` first scans the
producer's subscriber list to remove dead weak edges, then scans it again to
find the current consumer. Adding `N` consumers therefore takes O(N²) weak-edge
checks. At 1,200 consumers, that is about 1.44 million checks for one shared
producer. Storefront has several such producers. The arena links an integer
edge in O(1) and does not load weak references.

The interaction and control cuts are quiet enough to count allocations and ARC.
The table gives exact p90 values.

| Measure                       | interactions, simple | interactions, arena | control, simple | control, arena |
| ----------------------------- | -------------------: | ------------------: | --------------: | -------------: |
| allocations made              |                   33 |                  12 |           5,611 |          5,611 |
| allocations returned          |                   33 |                  12 |           5,611 |          5,611 |
| **allocations that survived** |                **0** |               **0** |           **0** |          **0** |
| gross bytes requested         |                9,279 |                 536 |         625,302 |        625,302 |
| **bytes that survived**       |                **0** |               **0** |           **0** |          **0** |
| object allocations            |                   33 |                  12 |           1,846 |          1,846 |
| retains                       |              145,023 |               2,741 |          11,381 |         11,381 |
| releases                      |              409,343 |               2,819 |          20,699 |         20,700 |

Both cores returned every byte used by a steady interaction. The control counts
match across cores, apart from one release. The graph-backed interaction matches
the subscriber diagnosis: simple used 53× as many retains and 145× as many
releases.

The footprint cut builds and keeps 2,402 states: one eligibility and one score
state per product, plus two gatherers. These are exact p90 values.

| Measure                         |        simple |         arena |
| ------------------------------- | ------------: | ------------: |
| allocations made                |        21,815 |        10,225 |
| allocations returned            |         3,761 |        10,150 |
| **allocations that survived**   |    **18,054** |        **75** |
| gross bytes requested           |     2,500,066 |     2,639,596 |
| **bytes that survived**         | **1,705,522** | **1,226,863** |
| object allocations              |        19,333 |           198 |
| retains                         |    10,200,449 |        60,476 |
| releases                        |    30,371,379 |        59,387 |
| surviving allocations per state |           7.5 |         0.031 |
| surviving bytes per state       |         710 B |         511 B |

The arena held 28% fewer bytes and used 241× fewer surviving allocations. Its
gross requested bytes were slightly higher because column growth replaces and
frees buffers.

This does not conflict with the arena's 2.2× loss on the simple 1,000-state
build. Each source in that test has only one consumer, so the simple core never
hits its high-fan defect. Storefront has both wide gatherers and shared
producers with thousands of consumers. That work costs much more than the
arena's cold generic-storage penalty.

## Older and withdrawn results

This section keeps earlier measurements in a compact form. Do not use a
superseded or withdrawn result as current evidence.

### Simple-core baseline before M9

`M5-06` and `M5-07a`, environment E1.

| Operation                |   mallocs |   objects |  retains |  releases |
| ------------------------ | --------: | --------: | -------: | --------: |
| keyed reference creation |         0 |         0 |        — |         — |
| steady turn              |         7 |         7 |    65–66 |     92–93 |
| 16-consumer fan          |        26 |        26 |    1,116 |     2,032 |
| added cost per consumer  | about 1.3 | about 1.3 | about 70 | about 129 |

Extra allocation probes from `M5-06`:

| Path                                   |    allocations |
| -------------------------------------- | -------------: |
| manual-source `peek`, 10,000 times     |  about 0 total |
| keyed reference creation, 10,000 times |        0 total |
| clean tracked read, 10,000 times       | about 12 total |
| clean automatic `peek`                 |         6 each |
| turn with no read                      |         6 each |
| turn plus tracked read                 |         7 each |

`M5-07b` measured the simple core's 1,000-state resident-memory growth at
0.87–1.28 MB at p50 and 1.28–1.56 MB at p100, or about 1.4 KB per state. This
sampled metric has a 1 MiB drift limit. Storefront's counted footprint later
gave a clearer result.

`M5-07d` measured the old pinned-key slope:

| Pinned keys | retains | releases | mallocs | p50 time |
| ----------: | ------: | -------: | ------: | -------: |
|           1 |      68 |       95 |       7 |   2.7 µs |
|         100 |     167 |      194 |       7 |   4.8 µs |
|         500 |     567 |      594 |       7 |    14 µs |

The old turn paid one retain and release for every pinned key. `M9-06` removed
this slope on both cores.

### First core decision

`M6-12a`, environment E1. Both cores passed the same 248 public scenarios.

| Workload        | Core   | mallocs / objects | retains / releases | p50 time |
| --------------- | ------ | ----------------: | -----------------: | -------: |
| steady turn     | simple |             7 / 7 |            66 / 93 | 2.202 µs |
| steady turn     | arena  |             5 / 5 |            48 / 67 | 2.425 µs |
| 16-consumer fan | simple |           26 / 26 |      1,132 / 2,048 |    40 µs |
| 16-consumer fan | arena  |             5 / 5 |          424 / 488 |    21 µs |

| Pinned keys | simple retains / releases / p50 | arena retains / releases / p50 |
| ----------: | ------------------------------: | -----------------------------: |
|           1 |              69 / 96 / 2.826 µs |             51 / 70 / 3.172 µs |
|         100 |            168 / 195 / 4.850 µs |           249 / 268 / 4.583 µs |
|         500 |               568 / 595 / 15 µs |          1,049 / 1,068 / 10 µs |

The arena reduced wide-graph work but still allocated and had a worse pinned-key
slope. The simple core stayed the default. Arena was kept for research. No
0.2.0 release was made because the planned core swap did not happen.

### Core comparison after shared M9 work

`M9-17`, environment E2. The simple numbers still stand. The arena numbers are
superseded by `M9-22` and `M9-23`.

| Workload          | Core   | mallocs | retains / releases | p50 time |
| ----------------- | ------ | ------: | -----------------: | -------: |
| steady turn       | simple |       0 |            62 / 75 | 1.639 µs |
| steady turn       | arena  |       1 |            47 / 56 | 2.198 µs |
| 16-consumer fan   | simple |       0 |      1,158 / 2,041 |    37 µs |
| 16-consumer fan   | arena  |       1 |          409 / 478 |    21 µs |
| 100-node chain    | simple |       0 |      3,963 / 4,576 |   128 µs |
| 100-node chain    | arena  |       1 |      1,248 / 1,257 |   109 µs |
| 1 pinned key      | simple |       0 |            65 / 78 | 2.072 µs |
| 1 pinned key      | arena  |       1 |            50 / 59 | 2.861 µs |
| 1,000 pinned keys | simple |       0 |            65 / 78 | 2.159 µs |
| 1,000 pinned keys | arena  |       1 |            50 / 59 | 2.902 µs |

| Workload | simple p50 | arena p50 | simple instructions | arena instructions |
| -------- | ---------: | --------: | ------------------: | -----------------: |
| diamond  |   4,551 µs |  4,219 µs |                84 M |              102 M |
| deep     |   2,279 µs |  2,724 µs |                43 M |               68 M |
| broad    |      12 ms |   9.08 ms |               221 M |              217 M |
| unstable |   2,410 µs |  1,248 µs |                43 M |               31 M |

At that point, the arena won broad and unstable graphs but lost the smallest
turn and the deep graph. Later arena work reversed the smallest-turn result.

### Storefront results withdrawn after review

The first headless runs, first cross-core comparison, first footprint reading,
and first UI run used the flawed harness listed in the correction section.
Their figures are not current evidence.

`M10-05`, environment E2, standard profile, simple core:

| Cut             | p50 time | instructions | mallocs | objects | retains | releases | samples |
| --------------- | -------: | -----------: | ------: | ------: | ------: | -------: | ------: |
| cold            |   555 ms |      7,998 M |       — |       — |       — |        — |      10 |
| session         | 6,178 ms |         88 G |       — |       — |       — |        — |       2 |
| interactions    | 1,340 µs |         20 M |      19 |      19 |    29 K |     79 K |   2,181 |
| async burst     |    80 ms |      1,158 M |       — |       — |       — |        — |      62 |
| compute control |   604 µs |         13 M |   5,603 |   1,838 |    11 K |     21 K |   4,167 |

`M10-08`, environment E2, standard profile:

| Cut             | simple p50 | arena p50 |
| --------------- | ---------: | --------: |
| cold            |     555 ms |     40 ms |
| session         |   6,178 ms |    195 ms |
| interactions    |   1,340 µs |     74 µs |
| async burst     |      80 ms |   6.23 ms |
| compute control |     604 µs |    657 µs |

| Interaction count | simple | arena |
| ----------------- | -----: | ----: |
| mallocs           |     19 |    12 |
| objects           |     19 |    12 |
| retains           |   29 K |   903 |
| releases          |   79 K |   950 |

The withdrawn 2,402-state footprint reading was:

| Measure                   |     simple |     arena |
| ------------------------- | ---------: | --------: |
| allocations made          |     21,815 |    10,225 |
| allocations returned      |      3,761 |    10,150 |
| allocations that survived |     18,054 |        75 |
| gross bytes requested     |  2,500,066 | 2,639,596 |
| bytes that survived       |  1,705,522 | 1,226,863 |
| object allocations        |     19,333 |       198 |
| retains                   | 10,200,449 |    60,476 |
| releases                  | 30,371,379 |    59,387 |
| instructions              |     7.10 G |     173 M |
| p50 time                  |     485 ms |   12.6 ms |

The values match the corrected footprint counts because that cut's measured
region did not contain the shadow checks. The result was still withdrawn with
the rest of the first run, then confirmed by the corrected run.

The first equal-iteration resident-memory run reported:

| Cut         | simple peak / delta, p50 | arena peak / delta, p50 | iterations |
| ----------- | -----------------------: | ----------------------: | ---------: |
| cold        |         22 MB / 1,983 KB |        32 MB / 5,018 KB |         10 |
| async burst |           21 MB / 820 KB |          28 MB / 508 KB |         50 |
| session     |         31 MB / 3,410 KB |        53 MB / 5,640 KB |          3 |

The first steady-allocation run reported:

| Measure                   | interactions, simple | interactions, arena | control, simple | control, arena |
| ------------------------- | -------------------: | ------------------: | --------------: | -------------: |
| allocations made          |                   19 |                  12 |           5,603 |          5,603 |
| allocations returned      |                   19 |                  12 |           5,603 |          5,603 |
| allocations that survived |                    0 |                   0 |               0 |              0 |
| gross bytes requested     |                3,448 |                 536 |         624,883 |        624,883 |
| bytes that survived       |                    0 |                   0 |               0 |              0 |
| object allocations        |                   19 |                  12 |           1,838 |          1,838 |
| retains                   |               29,064 |                 903 |          11,366 |         11,366 |
| releases                  |               78,976 |                 950 |          20,670 |         20,664 |
| instructions              |               19.8 M |              1.46 M |          12.9 M |         12.9 M |
| p50 time                  |              1.26 ms |             77.9 µs |          643 µs |         587 µs |

`M10-07`, environment E4, smoke profile. Five measured UI iterations followed
one warm-up. The app relaunched before each measured region.

| Test                             | Metric                |    mean |   RSD |
| -------------------------------- | --------------------- | ------: | ----: |
| cold launch                      | first frame           | 1.183 s | 1.32% |
| settled scrolling                | drag and deceleration | 2.584 s | 0.01% |
| scrolling during inventory burst | drag and deceleration | 2.567 s | 0.57% |
| search                           | clock                 | 0.372 s | 1.54% |
| search                           | app CPU time          | 0.225 s | 3.37% |
| search                           | app instructions      | 2.38 GI | 1.75% |
| search                           | app peak memory       | 72.6 MB | 0.12% |
| search                           | app absolute memory   | 71.4 MB | 0.11% |
| detail navigation                | navigation transition | 0.517 s | 0.34% |
| cart and checkout                | clock                 | 2.234 s | 2.23% |
| cart and checkout                | app instructions      | 3.18 GI | 0.21% |

SwiftUI `List` produced the UIKit scroll timing signpost, but the metric mostly
measured the fixed swipe and slowdown time. `XCTHitchMetric` returned no data.
Simulator results can be regression signals, but they cannot support a claim
about smoothness on a physical device.

## Measurement rules

- Allocation and ARC counters are process-wide. Use them only while the graph
  is quiet: no async work and no teardown after the timer.
- `mallocFreeDelta` is allocations minus frees during the timed window.
  `memoryLeakedBytes` is the matching balance in requested bytes. Neither is a
  full live-heap count.
- Resident memory is sampled and page-sized. Use it for large regressions, not
  small differences.
- Every timed sample checks its result and run count. Storefront also checks a
  shadow-model digest after timing.
- A zero-allocation gate must run `perf-witness-allocating` first. Otherwise a
  broken interposer could report a false zero.
- Storefront has no committed timing limit yet. One local session is not enough
  history for a stable CI limit.
