# Cog for Swift: benchmark results

_August 23, 2026_

This file records how the current build performs and what CI enforces about
it. The path here, including the retired simple core, the arena before its
typed frontier, the layout bake-offs, and every withdrawn result, lives in
[perf-history.md](./perf-history.md). If a number appears in both files, this
one wins.

The benchmark design is in [design/perf.md](../design/perf.md). Profiler
results and optimization details are in [optimization.md](./optimization.md).
Commands, tool versions, and threshold file formats are in the
[`swift/Benchmarks` README](https://github.com/skeswa/cog/blob/main/swift/Benchmarks/README.md).

In the tables below, p50 is the median and p90 is the 90th percentile. Lower
times, instruction counts, allocations, retains, and releases are better. ARC
means Swift's automatic reference-counting work. Each session has a plain name
and a short ID such as [E5](#benchmark-environment-e5); the
[environment table](#measurement-environments) gives its date, machine, OS,
Xcode, Swift, and harness.

## The shipping core

Cog ships one core: the **specialized arena**. It stores state in columns,
edges in a shared integer pool, and exposes a typed frontier of stable
`@inlinable` entry points so client builds specialize the generic value work.
`CompactArena` is the one build-time option: it turns the typed frontier off
to keep the binary smaller and changes nothing else. How this core won is
recorded in [perf-history.md](./perf-history.md); the numbers below are what
it does today.

### Warm work

From the [specialization run (E5)](#benchmark-environment-e5). The steady-turn
figure is the median of three independently recorded p50s.

| Shape           | p50     | notes                                                                                        |
| --------------- | ------- | -------------------------------------------------------------------------------------------- |
| steady turn     | 909 ns  | zero allocations; 18 retains in the later [small-site run (E12)](#benchmark-environment-e12) |
| 16-consumer fan | 7.6 µs  | zero allocations                                                                             |
| 100-node chain  | 64 µs   | zero allocations                                                                             |
| pinned-key turn | ~2.4 µs | flat from 1 to 1,000 pinned keys                                                             |

For scale against a UI budget: a 120 Hz frame is 8.3 ms, so one frame fits
about 9,000 steady turns, 1,000 fan updates, or 130 full 100-node chain
settlements. A whole Storefront interaction, which writes state and settles a
23-node path through a 16-stage pricing chain, takes about 2% of one frame.

### Whole-graph propagation, in perspective

The [current runtime comparison (E9)](#benchmark-environment-e9) ran all
twelve `perf-10-*` benchmarks in one session: the shipping core, raw
`@Observable`, and swift-state-graph 0.28.0 on the same four shapes. Raw
Observation is the floor, not a competitor: it is hand-written invalidation
with no automatic-value cache, so it shows what the hardware and Observation
itself cost before any library features. swift-state-graph is the closest
library. Each cell shows p50 time and p50 instructions.

| Shape    | raw `@Observable` (floor) | Cog             | swift-state-graph | Cog vs. floor | Cog vs. swift-state-graph |
| -------- | ------------------------- | --------------- | ----------------- | ------------: | ------------------------: |
| diamond  | 788 µs / 16 M             | 1,530 µs / 37 M | 25 ms / 505 M     |          1.9× |                16× faster |
| deep     | 202 µs / 4.1 M            | 697 µs / 18 M   | 14 ms / 300 M     |          3.5× |                20× faster |
| broad    | 2,055 µs / 45 M           | 3,703 µs / 88 M | 36 ms / 721 M     |          1.8× |               9.7× faster |
| unstable | 324 µs / 7.1 M            | 471 µs / 12 M   | 7,471 µs / 153 M  |          1.5× |                16× faster |

So the caching, glitch-free consistency, and dependency tracking Cog adds on
top of raw Observation cost 1.5× to 3.5× on these shapes, and the same
features cost 10× to 20× more in swift-state-graph. The gap to the floor is
widest on the deep chain, where Cog walks 100 cache nodes the raw version
does not have. These numbers supersede the E6 whole-graph column as the
current figures; E6 remains the recorded three-core retirement evidence in
[perf-history.md](./perf-history.md#retiring-the-simple-core).

### Building a keyed graph

From the [specialization run (E5)](#benchmark-environment-e5): building and
settling 500 keyed sources and 500 keyed consumers takes 1,102 µs at p50 with
1,699 allocations in the standalone probe, within 3% of the fastest time any
core ever posted on this shape. Resident memory lands near 1.5 MB, but that
metric is sampled in whole pages; Storefront's counted footprint below is the
better memory measure.

## CompactArena: what the size opt-out costs

`CompactArena` runs the same graph engine without the typed frontier, so
generic value work stays unspecialized. That trades speed for binary size.

**Speed.** The [paired arena-configuration run (E7)](#benchmark-environment-e7)
priced the trade on the Storefront workload; the full table is in the
[Storefront section](#specialized-default-versus-compactarena) below. In
short: steady interactions cost 11% more, the async burst 7% more, a full
session 29% more, cold start 57% more, and building the 2,402-state footprint
about 2.1× more. Construction is where the frontier matters most: the paired
[E5](#benchmark-environment-e5) build-and-settle ran 2,163 µs without the
frontier against 1,102 µs with it, and cold construction under `CompactArena`
also allocates through generic storage, about 10,000 mallocs against the
default's 177 on the footprint build.

**Size.** Retained clean release artifacts measured the arm64 Mach-O `__TEXT`
segment. Turning the typed frontier off is exactly what `CompactArena` does,
so the frontier-off artifact is the compact measurement:

| Artifact            | with typed frontier | frontier off (`CompactArena`) | saved by compact |
| ------------------- | ------------------: | ----------------------------: | ---------------: |
| `CogGraph` `__TEXT` |           2,670,592 |                     2,506,752 |  163,840 (-6.1%) |

For scale, the whole Storefront executable's `__TEXT` segment measured
991,232 bytes with the frontier on, 19.8% more than the same app on the
retired simple core; a compact Storefront artifact has not been measured yet.
These are executable code segments, not app bundle or download size. The cost
of the frontier grows with the number of value and key types a program uses,
not with how much state it holds at runtime. Pick `CompactArena` when the size
budget matters more than the measured speed; because traits are additive,
libraries should leave that choice to the application.

## Cost gates

These are the invariants CI holds, checked by `mise run bench:thresholds:check`
on the pinned host. The gate first runs an allocating witness so a broken
counter cannot report a false zero, and `mise run bench:thresholds:sentinel`
proves the gate rejects an impossible limit. The `bench:compact` task does not
apply these thresholds.

- **A steady turn allocates nothing.** The committed `perf-01-steady-turn`
  threshold requires exactly zero mallocs at p90, not a tolerance around
  zero. ARC is not zero: a steady turn retains exactly 18 times after
  the M11-02 through M11-04 cuts, and issue #373 and milestone M11 track the
  rest.
- **Settling a node allocates nothing.** The committed `perf-13-deep-chain`
  threshold holds the per-node allocation count at zero.
- **Building a keyed reference allocates nothing.** The committed
  `perf-06-value-reference` threshold.
- **Pinned keys cost O(changed keys).** A turn that writes one key costs the
  same whether 1 or 1,000 other keys stay pinned. The committed
  `perf-11-pinned-key-slope-1000` threshold allows at most 90 retains and 110
  releases per turn.
- **Observation boundaries stay lazy.** With 1,000 states and 12 tracked
  reads, exactly 12 boundary objects exist. The exact count is asserted, not
  bounded.

### Absolute CI limits

The committed `perf-10-*` wall-clock ceilings catch large regressions on the
diamond, deep, broad, and unstable shapes. Each limit is about three times the
slower p90 recorded in the [initial baseline (E1)](#benchmark-environment-e1)
session, when Cog's cores were much slower, so the current build clears them
with a wide margin. The current three-runtime figures are in the comparison
section above; E1's original four-runtime table is in
[perf-history.md](./perf-history.md#the-external-runtime-comparison).

| Runtime           | recorded p90: diamond / deep / broad / unstable | limits: diamond / deep / broad / unstable |
| ----------------- | ----------------------------------------------- | ----------------------------------------- |
| Cog               | 5.231 / 2.750 / 13 / 2.755 ms                   | **20 / 10 / 40 / 10 ms**                  |
| raw `@Observable` | 0.820 / 0.216 / 2.277 / 0.350 ms                | **3 / 1 / 8 / 2 ms**                      |
| swift-state-graph | 26 / 15 / 37 / 7.696 ms                         | **80 / 50 / 120 / 25 ms**                 |

Storefront has no committed limit yet. The
[threshold decision](#storefront-threshold-decision) names two candidate
gates and the pinned-runner session that must confirm them first.

## Storefront macrobenchmark

Storefront combines many graph shapes in one commerce session. It runs through
the shared package both headlessly and through SwiftUI. It is a
**representative workload v1**, not a claim about an average app. Its first
harness had five measurement bugs; the withdrawal and what the correction
changed are recorded in
[perf-history.md](./perf-history.md#the-storefront-correction).

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
| `Cog.Manual`     |    12 |
| `CogBox.Manual`  |     5 |
| `Cog`            |    18 |
| `CogBox`         |     8 |
| `Cog.Async`      |     7 |
| `CogBox.Async`   |     3 |

The longest useful path is 23 nodes. The workload covers search over the full
catalog, keyed async state, a 16-stage pricing chain, multi-source writes,
cart totals, stale async results, replaced requests, and release after a grace
period. It does not cover several screens alive at once, real network or disk
work, memory pressure, a full navigation history, or physical-device
performance.

### Specialized default versus CompactArena

The [paired arena-configuration run (E7)](#benchmark-environment-e7) covered
`M10-08` with the standard profile: `mise run bench` and
`mise run bench:compact` over every `perf-15-storefront-*` cut, back to back
in one session, after `mise run test:storefront` passed all 12 tests. This is
the binary-size opt-out's runtime price on an application-shaped graph.
Report-only: one host, one session, and Xcode 26.4 rather than the pinned
release toolchain.

| Cut                                  | specialized p50 | compact p50 | compact cost | specialized instructions | compact instructions | samples, spec / compact |
| ------------------------------------ | --------------: | ----------: | -----------: | -----------------------: | -------------------: | ----------------------: |
| `perf-15-storefront-cold`            |           21 ms |       33 ms |         +57% |                    457 M |                793 M |                 10 / 10 |
| `perf-15-storefront-session`         |          131 ms |      169 ms |         +29% |                  2,741 M |              3,756 M |                   3 / 3 |
| `perf-15-storefront-interactions`    |          178 µs |      197 µs |         +11% |                   4.01 M |               4.52 M |           2,640 / 2,577 |
| `perf-15-storefront-async-burst`     |         3.74 ms |     3.99 ms |          +7% |                     63 M |                 68 M |                 50 / 50 |
| `perf-15-storefront-footprint`       |         3.60 ms |     7.43 ms |        +106% |                     81 M |                174 M |                   3 / 3 |
| `perf-15-storefront-compute-control` |          529 µs |      542 µs |        +2.5% |                     13 M |                 13 M |           5,262 / 5,123 |

The control holds no graph, and its +2.5% sits inside its own p25–p75 spread,
so the harness held still. The trait's costs land exactly where the typed
frontier works: cold build, the footprint build, and the full session. A
steady interaction and the async burst stay close. Allocation behavior is
identical where the interposer counted it, 12 mallocs per interaction and
5,611 per control run under both configurations, except the footprint build,
where compact pays about 10,000 mallocs to the default's 177.

This run also gave the specialized executable its corrected headless timing.
It beats the pre-frontier arena numbers from the
[corrected Storefront run](./perf-history.md#retiring-the-simple-core) on
every graph-backed cut: cold 34 → 21 ms, session 178 → 131 ms, interactions
201 → 178 µs, async burst 4.09 → 3.74 ms, footprint 7.29 → 3.60 ms.

### UI results

The [corrected Storefront UI run (E8)](#benchmark-environment-e8) covered
`M10-07`: the release-configuration `StorefrontUITests` suite on the pinned
iPhone 17 Pro simulator (iOS 26.4, 23E244), smoke profile, through
`mise run test:storefront-ui` with its nonzero-executed-count guard. All 8
tests passed, five samples per metric. Medians:

| Measure                                          |   median (n = 5) |
| ------------------------------------------------ | ---------------: |
| Cold launch to responsive first frame            |          1.194 s |
| Settled scroll, drag-and-deceleration signpost   |          2.568 s |
| Scroll during inventory burst, same signpost     |          2.567 s |
| Detail navigation transition                     |          0.518 s |
| Search interaction, wall clock                   |          0.382 s |
| Search interaction, app CPU time / instructions  | 0.212 s / 2.28 G |
| Search interaction, app peak physical memory     |          73.3 MB |
| Cart checkout block, wall clock                  |          2.257 s |
| Cart checkout block, app CPU time / instructions | 0.354 s / 3.17 G |

The two scroll signposts are the load-bearing pair: the gesture-bound
drag-and-deceleration duration is the same to within 1.5 ms whether the feed
is settled or a deterministic inventory burst is writing offscreen rows. That
is the "offscreen updates do no visible work" claim, measured at the
interface. `XCTHitchMetric` contributed no series on the simulator, as
`StorefrontScrollPerformanceUITests` records, so no hitch figure is reported.
Every number here is a pinned-host regression signal, not a user-experience
guarantee: the simulator runs on the host's CPU and window server, and
absolute hitch or latency targets belong on a pinned physical device.

### Storefront threshold decision

`M10-09`, decided August 23, 2026, on the E7, E8, and E9 evidence.

**Two cuts earn CI thresholds; the rest stay report-only.** The named
candidates are:

- `perf-15-storefront-interactions`: an exact 12-malloc p90 gate, in the
  style of the steady-turn zero gate, plus a one-sided wall-clock ceiling of
  600 µs, about three times the recorded p90 of 188 µs.
- `perf-15-storefront-compute-control`: an exact 5,611-malloc p90 gate plus a
  one-sided ceiling of 1.7 ms, about three times the recorded p90 of 556 µs.
  Gating the control pins the harness itself: if the control drifts, the
  measurement moved, not Cog.

Both cuts run thousands of samples per session, so their percentiles are
stable. Cold, session, and footprint run 3 to 10 samples and the async
burst's variance is scheduler-shaped, so none of them gets a ceiling.

**What CI must confirm first.** The thresholds are named here but not
committed. Committing them requires one paired session on the pinned runner
that reproduces the E7 cuts, because every current number is from `mactop` on
Xcode 26.4, and a threshold committed from the wrong host would gate CI
against a machine it does not run on.

**Where cold-start time goes.** Partly unknown, and recorded as such: of the
21 ms cold start, the footprint build accounts for roughly 3.6 ms, and the
rest is unattributed between first settlement, async scheduling, and fixture
work. The phase-split probe below is the scheduled work that answers this.

**Follow-up work.** None of it blocks closing M10:

1. The pinned-runner paired session, which also commits the two named
   thresholds and repeats the [E8](#benchmark-environment-e8) UI suite there.
2. The phase-split probe: build, first settlement, and teardown measured as
   separate phases under one profiler boundary, to attribute cold start.
3. A compact Storefront artifact measurement, to complete the size table.
4. Carried from before this decision: repeat the three-runtime comparison on
   the pinned Xcode, and qualify the specialized and `CompactArena` release
   archives there.

## Measurement environments

All benchmark runs used release builds.

| ID                                        | Run name                                  | Date       | Environment                                                                                                                                                                                                                                                                          |
| ----------------------------------------- | ----------------------------------------- | ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| <a id="benchmark-environment-e1"></a>E1   | Initial baseline                          | 2026-08-17 | `mactop`, Apple Silicon arm64, 12 cores, 24 GB, macOS 26.4.1 / Darwin 25.4.0, Xcode 26.4 (17E192), Swift 6.3.0, harness 1.36.2                                                                                                                                                       |
| <a id="benchmark-environment-e2"></a>E2   | Shared-runtime run                        | 2026-08-19 | `mactop`, Apple Silicon arm64, 12 cores, 24 GB, macOS 26.4.1 / Darwin 25.4.0, Xcode 26.4 (17E192), Apple Swift 6.3, harness 1.36.2                                                                                                                                                   |
| <a id="benchmark-environment-e3"></a>E3   | Corrected Storefront run                  | 2026-08-20 | `mactop`, Apple M4 Pro arm64, 12 cores, 24 GB, Xcode 26.4 (17E192), Apple Swift 6.3, harness 1.36.2; both cores ran back to back on an idle host                                                                                                                                     |
| <a id="benchmark-environment-e4"></a>E4   | Storefront UI smoke                       | 2026-08-19 | `mactop`, Xcode 26.4 (17E192), iPhone 17 Pro simulator on iOS 26.4 (23E244), arm64, Storefront smoke profile                                                                                                                                                                         |
| <a id="benchmark-environment-e5"></a>E5   | Specialization run                        | 2026-08-21 | `mactop`, Apple M4 Pro arm64, 12 cores, 24 GB, macOS 26.4.1, Xcode 26.4 (17E192), Apple Swift 6.3, harness 1.36.2; seven paired PERF-03 runs and three specialized warm sweeps; not a release check                                                                                  |
| <a id="benchmark-environment-e6"></a>E6   | Three-core comparison                     | 2026-08-21 | `mactop`, Apple M4 Pro arm64, 12 cores, 24 GB, macOS 26.4.1 / Darwin 25.4.0, Xcode 26.4 (17E192), Apple Swift 6.3, harness 1.36.2; PERF-10 ran simple, unspecialized arena, then specialized arena back to back                                                                      |
| <a id="benchmark-environment-e7"></a>E7   | Paired arena-configuration Storefront run | 2026-08-23 | `mactop`, Apple M4 Pro arm64, 12 cores, 24 GB, macOS 26.4.1 / Darwin 25.4.0, Xcode 26.4 (17E192), Apple Swift 6.3, harness 1.36.2; specialized default and `CompactArena` ran back to back on an idle host after `mise run test:storefront` passed; not a release check              |
| <a id="benchmark-environment-e8"></a>E8   | Corrected Storefront UI run               | 2026-08-23 | `mactop`, Xcode 26.4 (17E192), iPhone 17 Pro simulator on iOS 26.4 (23E244), arm64, release configuration, smoke profile, five samples per metric through `mise run test:storefront-ui`                                                                                              |
| <a id="benchmark-environment-e9"></a>E9   | Current runtime comparison                | 2026-08-23 | `mactop`, Apple M4 Pro arm64, 12 cores, 24 GB, macOS 26.4.1 / Darwin 25.4.0, Xcode 26.4 (17E192), Apple Swift 6.3, harness 1.36.2; all twelve `perf-10-*` benchmarks in one session on an idle host: shipping core, raw `@Observable`, swift-state-graph 0.28.0; not a release check |
| <a id="benchmark-environment-e10"></a>E10 | Turn-machinery ARC run                    | 2026-08-23 | `mactop`, Apple M4 Pro arm64, 12 cores, 24 GB, macOS 26.4.1 / Darwin 25.4.0, Xcode 26.4 (17E192), Apple Swift 6.3, harness 1.36.2; `perf-01-steady-turn` after the M11-02 cuts, 3,908 samples, exact at every percentile; not a release check                                        |
| <a id="benchmark-environment-e11"></a>E11 | Record-borrow run                         | 2026-08-23 | `mactop`, Apple M4 Pro arm64, 12 cores, 24 GB, macOS 26.4.1 / Darwin 25.4.0, Xcode 26.4 (17E192), Apple Swift 6.3, harness 1.36.2; `perf-01-steady-turn` after the M11-03 record borrows, 4,177 samples, exact at every percentile; not a release check                              |
| <a id="benchmark-environment-e12"></a>E12 | Small-site run                            | 2026-08-23 | `mactop`, Apple M4 Pro arm64, 12 cores, 24 GB, macOS 26.4.1 / Darwin 25.4.0, Xcode 26.4 (17E192), Apple Swift 6.3, harness 1.36.2; `perf-01-steady-turn` after the M11-04 small-site cuts, 4,104 samples, exact at every percentile; not a release check                             |

Runs with malloc and ARC counters used the malloc interposer. The edge-layout
run used interposer 1.4.0. The external runtime comparison used
swift-state-graph 0.28.0 at revision
`e602fcdb19342a38c135543e7228b3fd60753dc7` and SwiftSyntax 603.0.2.

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
