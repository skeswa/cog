# Cog for Swift: benchmark results

_August 20, 2026_

Numbers, and only numbers that were actually taken. Each entry names the task
that recorded it and the environment it came from; a threshold with no
measurement behind it is a guess that fails at the worst moment.

This document is the measurement record. It was split out of
[design/perf.md](../design/perf.md), which owns the design — the cost order, the
representation, the ARC and exclusivity rules, and the measurement plan these
numbers execute. Keeping them apart is the point: a reader who wants to know
_why_ Cog is shaped this way reads the design; a reader who wants to know _what
it currently costs_ reads here. Bare section references such as `perf §5` resolve
in that document.

Two neighbours carry the rest. Profiler attribution — where the time actually
goes, and what each optimization bought — is in
[optimization.md](./optimization.md), because it is obtained with a sampler and
purpose-built probes rather than with the benchmark suite. How to run the suite,
its pinned tool matrix, its quiescence rules, and how a committed threshold is
encoded are in [`swift/Benchmarks/README.md`](../../../swift/Benchmarks/README.md).

Below the summary that follows, entries appear in the order they were recorded,
and they back-reference each other — "same session and environment" means the
entry above. Nothing is reordered for tidiness, and a withdrawn entry keeps its
place with the withdrawal in its heading rather than being deleted, because an
audit trail that loses its mistakes is not one. The summary is the exception: it
is assembled from those entries rather than being one of them, and it names the
record behind every figure it quotes.

## Where the two cores stand

The most pressing open question in this record is which implementation to carry
forward, so it goes first. The shipping default is the **simple core** —
class states, edge arrays — selected by `M6-12a`. The **arena core** — scalar
columns and a shared linked edge pool — stays behind `COG_TEST_CORE=arena` as a
behaviour-equivalent research build. `M9-18` owns the decision to revisit that,
and it has not been recorded yet.

Everything below is assembled from standing records only. **Every Storefront
number in this document is withdrawn** by the measurement-integrity correction,
and contributes nothing to this summary — which matters, because the Storefront
was the one workload built to answer this question on an application shape.

### What each core currently wins

Warm execution, from `M9-23` — the most recent measurement, after `M9-22` and
`M9-23` removed the arena's exclusivity and metadata costs:

| Shape                 |   simple |    arena | winner           |
| --------------------- | -------: | -------: | ---------------- |
| steady turn, p50      | 1,639 ns | 1,337 ns | arena, by 18%    |
| steady turn, retains  |       62 |       38 | arena            |
| 16-consumer fan, p50  |    37 µs |    13 µs | arena, by 2.8×   |
| 100-node chain, p50   |   128 µs |    94 µs | arena, by 27%    |
| pinned-key turn, p50  |  ~2.2 µs |  ~2.6 µs | **simple**, ~15% |
| allocations, all four |        0 |        0 | tie              |

Construction, from `M9-25` — seven paired runs of a thousand-state keyed graph,
built and settled in a fresh context each time:

| Measure                        |    simple |     arena | winner              |
| ------------------------------ | --------: | --------: | ------------------- |
| build + settle + teardown, p50 | ~1,068 µs | ~2,320 µs | **simple**, by 2.2× |
| resident-memory delta, p50     | ~1,345 KB | ~1,541 KB | not separable       |

The memory row is not a result: the ranges overlap so heavily that the arena's
best run is below the simple core's worst. Route F is still open, and answering
it needs a counted probe rather than this sampled metric.

So the trade, stated plainly: **the arena is faster to run and slower to build**,
and it carries a third to a half of the simple core's ARC traffic — which is
perf §5's rule, still unmet by the shipping core and still the largest single
item in its steady turn.

### One thing here is inferred, not measured

The four whole-graph shapes — diamond, deep, broad, unstable — were last
measured at `M9-17`, whose arena column is superseded. `M9-22` and `M9-23` then
took 21% and a further 22% off the arena's turn, which is enough to turn
`M9-17`'s one arena loss (deep, by 20%) into a win. That is why `M9-23` and the
`M9-18` charter both read "the arena wins every whole-graph shape".

**Nobody has re-run that table.** It is an inference from two measured
improvements, and it should be re-measured before it decides anything.

### Both remaining arena losses are the same defect

`M9-26` traced the 2.2× build cost to the erased-storage crossing: an arena
state is split across scalar columns and a per-descriptor generic
`CogArenaValueColumn<Value>`, reached through an `AnyObject` and recovered as
its concrete type at every touch. That instantiates metadata and looks up
witness tables, and construction pays it per state.

`M9-23`'s memo files the resolved slot-and-column pair on the declaration and
removes that cost — but **only for a keyless declaration**, because one
declaration names a whole keyed family and a single-entry memo would thrash
between its members. The build workload is a hundred percent keyed. So the
arena's build loss and its pinned-key loss are not two problems; they are one
problem seen twice, and the route out of both is specialization rather than
another cache.

### The judgement

**Keep the simple core as the default today.** Not because it wins — on warm
execution it does not — but because the evidence that would decide the question
is missing, a core swap is a representation change with a release implication,
and `M6-12a` already took this decision once on weaker evidence than we have
now.

**But the arena has the better cost/benefit going forward**, and that is a
different question from which one ships today. Two reasons:

- **The trend.** The arena lost the smallest turn by 10% at `M6-11c`, by 34% at
  `M9-17`, and now wins it by 18% — without ever changing its representation.
  Every one of those gains came from removing an overhead the profile located.
- **The nature of what is left.** The simple core's dominant remaining cost is
  ARC in graph walks, which is intrinsic to class states and existential
  dependency arrays — you do not fix it without becoming something like the
  arena. The arena's dominant remaining cost is unspecialized generic code,
  which is a compiler-visible problem with a known route.

One is a property of the design; the other is a build-output problem. That
asymmetry, not any current number, is the strongest argument in the record.

### What would move the decision

1. **A rerun of the corrected Storefront macrobenchmark on both cores.**
   Synthetic shapes cannot answer "better for an application", which is why this
   workload exists; its numbers are withdrawn and it has not been rerun.
2. **Whether specialization is reachable without widening the public API.**
   `M9-24` and `M9-26` reached the same conclusion from opposite ends. If it is
   reachable, the trade collapses into a straight win and the question is
   settled. If it is not, the trade stands and app shape decides.
3. **A re-measured whole-graph table**, so the claim above rests on a
   measurement rather than on arithmetic applied to a superseded one.
4. **A counted footprint probe**, since the sampled one cannot separate them.

## Representation: allocation, ARC, and footprint

**Allocation, simple core** — `M5-06`, 2026-08-17, `mactop` (Apple Silicon,
12 cores), Xcode 26.4 / Swift 6.3.0, release, harness 1.36.2 with the malloc
interposer. Scaled per operation, and byte-identical from p0 to p100 across
1,300+ samples, so these are exact costs rather than distributions.

| Operation                                 | `mallocCountTotal` | `objectAllocCount` | Scenario                  |
| ----------------------------------------- | ------------------ | ------------------ | ------------------------- |
| `box[key]` value-reference creation       | **0**              | **0**              | PERF-06, green as written |
| Steady turn (one write, one tracked read) | **7**              | **7**              | PERF-01, ceiling recorded |

The steady turn does not reach zero on the simple core, which is the expected
state of the class-state build rather than a defect: perf §9.1 builds it from class
states and edge arrays, and perf §5's no-ARC, no-existential rules are what the
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
what perf §5's "no ARC, locks, or existentials in graph walks" rule buys — in M6,
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

Stated as a range on purpose. This is the one metric in this record that is _sampled_
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
worded, and the only figure in this record that is already exactly what the scenario
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

## Selecting the value-reference layout

**Value-reference layout: baseline recorded, candidates pending** —
`M5-09a`, 2026-08-17. The layout choice now lives behind one internal type,
`CogKey`, selected at build time by `COG_TEST_VALUE_REFERENCE_LAYOUT` and
verified by an infrastructure test that compares what the environment asked for,
what the test target compiled, and what the _library_ compiled — the third
comparison being the one that matters, since the layout is a library setting
chosen by a test runner.

The recorded baseline candidate is **inline `AnyHashable`**, the correctness
core's layout: one existential box per reference, keys of three words or fewer
stored inline and larger ones allocating. Every number above was
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
on every construction for that result would violate the cost order in perf §1.

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

## Selecting the edge layout

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
perf §5's graph-walk rule, and the measured churn result does not justify a nested
array per state. Inline plus overflow is structurally more complex and wins
neither workload.

The shared pool is therefore the ordinary arena build. It keeps one compact
entry per edge, reconciles stable ordered reads in place, and recycles removed
entries through an index free list without per-edge ARC. Prefix and inline
remain test-and-benchmark-only so COUNT-09 and PERF-09 can reproduce the
comparison.

## Pinned keys

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
for M6, where perf §5's "no ARC, locks, or existentials in graph walks" and perf §7's
dirty-set propagation are the rules that turn it into O(changed). All three
points stay in the suite so M6 can show the slope going flat rather than merely
showing one number get smaller.

## The runtime comparison and the core decision

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

## After M9's shared-machinery work

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
turn with one consumer. That is perf §5's rule still unmet, and it belongs to the
routes issue #373 keeps — borrowed descriptor records, unsafe buffers, and the
hashing follow-ups — not to a core swap. `M9-17` remeasures before anything
else is promoted.

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
releases per node. perf §5's "no ARC in graph walks" rule remains unmet on the
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
traffic is three to four times lower, and that is perf §5's rule, still unmet by the
shipping core and still the largest single item in a steady turn.

**Footprint and build cost, both cores** — `M9-25`, 2026-08-19, same host and
toolchain. Issue #373 route F asked for this: this record had a per-state figure for
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
simple core's worst — that seven pairs cannot separate them. This is the metric this record already flags as sampled rather than counted: resident memory is
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

## The Storefront macrobenchmark

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

**Measurement-integrity correction** — 2026-08-20. A review found five defects
in the first Storefront harness and workload:

- cold and session timings built an independent shadow catalog and evaluated
  its expensive checkpoints inside `startMeasurement()` / `stopMeasurement()`;
- draining saw only requests that had reached the service actor, leaving a gap
  for graph-selected tasks that had not begun executing;
- the retained interaction cut reset its index per sample and mapped every
  product to one fixed quantity, so later samples increasingly measured
  equality-gated no-ops and never checked their rendered result;
- every pricing stage read the product index and selected variant even when its
  policy did not use either input, widening invalidation below the graph shape
  this workload claims to represent; and
- the compute control looked cart prices up in the search-candidate table even
  though the standard cart products are not search candidates, silently falling
  back to list prices instead of running their pricing ladders.

The corrected harness prepares immutable shadow fixtures before timing,
suppresses phase-check evaluation during reported samples, and validates the
final shadow digest after timing. Async selectors register requests
synchronously in a scheduled-work ledger before returning their tasks; a drain
is complete only when both that ledger and the actor's suspended set are empty.
Steady interactions use one monotonic sequence across warmups and samples,
alternate quantities, advance variants, and replay into the shadow after the
timer. Pricing stages now read only policy inputs. The control prices every cart
line directly, and a committed semantic signature covers its whole output.

These are workload and measurement-boundary changes, not an optimization. All
Storefront numbers recorded before this correction — including the headless
core ratios, steady allocation tables, resident-memory readings, footprint
table, and simulator UI figures below — are retained as an audit trail but are
**withdrawn as current evidence**. They must not be compared with corrected
runs or used to choose a core. No replacement numbers are recorded here until
both cores and the UI application are rerun under their pinned environments.

**The Storefront macrobenchmark, first measurements — withdrawn** — `M10-05`, 2026-08-19,
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

**The Storefront macrobenchmark across cores — withdrawn** — `M10-08`, same
host, toolchain, and session. Both cores were measured back to back on the
standard profile. The old harness evaluated its checks inside the measured
region, which is one of the defects corrected above.

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

**What the Storefront graph cost to hold — historical, remeasure required** —
`M10-05`, 2026-08-19, same host and toolchain, standard profile.
`perf-15-storefront-footprint` builds the
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

**And the ARC column is the mechanism from the core comparison above, quantified.**
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

**Resident memory, with iteration counts pinned — withdrawn** — same session. The earlier
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
is sampled and page-granular, and perf §9 already names reserving capacity from known
descriptor counts as the fix if it matters.

**Steady-state allocation — withdrawn** — same session, exact p90 integers. The
old interaction sequence is one of the defects corrected above, so its zero-net
result does not describe the corrected workload. One iteration of the
quiescent interaction loop is a favorite toggle,
a cart quantity, a variant selection, and the two-source open-product verb; one
pass of the compute-only control runs all four kernels over the same catalog
with no graph at all.

| Measure                       | interactions, simple | interactions, arena | control, simple | control, arena |
| ----------------------------- | -------------------: | ------------------: | --------------: | -------------: |
| allocations made              |                   19 |                  12 |           5,603 |          5,603 |
| allocations returned          |                   19 |                  12 |           5,603 |          5,603 |
| **allocations that survived** |                **0** |               **0** |           **0** |          **0** |
| gross bytes requested         |                3,448 |                 536 |         624,883 |        624,883 |
| **bytes that survived**       |                **0** |               **0** |           **0** |          **0** |
| object allocations            |                   19 |                  12 |           1,838 |          1,838 |
| retains                       |               29,064 |                 903 |          11,366 |         11,366 |
| releases                      |               78,976 |                 950 |          20,670 |         20,664 |
| instructions                  |               19.8 M |              1.46 M |          12.9 M |         12.9 M |
| wall clock                    |              1.26 ms |             77.9 µs |          643 µs |         587 µs |

Both delta rows read **zero at every percentile** across thousands of samples on
both cores. A shopper's interaction returns every byte it takes; nothing about a
steady session grows the heap. That is the property a gate would eventually want,
and it is already true.

What moves is the gross column, and it moves the same way everything else in this
workload does: the same four writes against the same graph request 3,448 bytes on
the simple core against the arena's 536, and cost 29,064 retains against 903.

The control is the check on all of it. Across the core swap it is **byte
identical** — 5,603 allocations, 624,883 bytes, 1,838 object allocations, 11,366
retains — differing only by six releases and wall-clock noise, because it holds
no graph for a core swap to change. A comparison whose control moved would not be
a comparison.

**The Storefront application, first measurements — historical, remeasure
required** — `M10-07`, 2026-08-19,
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
| search interaction                  | absolute physical memory, app process         | 71.4 MB | 0.11% |
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

One figure is deliberately not in the table: the per-iteration physical-memory
_delta_, which swings 39% and goes negative and is unusable as anything. The
absolute and peak figures beside it are stable to a tenth of a percent and are
the ones worth tracking — and they are the whole app, a SwiftUI process with a
120-product catalog, not the graph's own footprint. For that, read the
`perf-15-storefront-footprint` entry above, which counts bytes rather than
sampling residency. Nothing here is gated: the suite runs from `mise run test:storefront-ui` when a number
is wanted, not on every pull request, because a six-and-a-half-minute timing
test on a shared machine teaches people to rerun rather than to look.

## Measurement integrity

**A zero threshold can pass because nothing was measured.** `M5-05bb` found
that a run with the malloc interposer disabled reports `mallocCountTotal == 0`
for a workload that demonstrably allocates. `perf-witness-allocating` exists as
the control — a benchmark that must always report a non-zero count — and
`M5-08a` owes the floor assertion, because upstream thresholds are upper bounds
and cannot express one.
