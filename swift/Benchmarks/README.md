# Cog benchmarks

A **separate SwiftPM package**, not a target of the root one. That is the whole
design of this directory.

SwiftPM hands a package's dependencies to everyone who resolves it, so a
benchmark harness, an allocator backend, or a baseline-checking CLI added to the
root manifest would land in the dependency graph of every app that adds Cog. The
root package resolves with **no dependencies at all** — swift-docc-plugin is
gated behind `COG_DOCC=1` for exactly the same reason — and that is a shipped
property of the library rather than a tidiness preference.

The relationship runs one way only. This package depends on the root by path;
nothing in the root manifest references this directory. `M5-05a` proved it by
describing both manifests:

```console
$ swift package show-dependencies --format json          # root
cog

$ swift package --package-path swift/Benchmarks show-dependencies --format json
benchmarks
  cog
```

The dependency is a **path**, never a version. Benchmarks measure the working
tree, so resolving Cog from a tag would make every measurement a statement about
a commit that is not the one being changed.

## Running it

From this directory:

```console
swift package benchmark
```

Or `mise run bench` from the repository root, which wraps exactly this and
passes extra arguments through. The plugin always builds release; a debug
measurement of a graph library measures the optimizer's absence.

CI runs the committed threshold gate on every Swift change (`bench-build`). It
stays on the pinned bare Apple Silicon mini, whose one-job runner and global
benchmark concurrency group prevent a timing run from sharing the machine with
another job.

## What is here today

One target, `CogGraph`, carries the allocation, graph-shape, layout,
four-runtime comparison, and Storefront macrobenchmark workloads described
below. Baseline tolerances pin
counting metrics against drift. Committed static files add the portable CI
gate: PERF-06's exact zero-allocation p90 plus PERF-10's generous wall-clock
ceilings.

Benchmarks drive the scenarios from `_CogScenarios`, the same values
`CogScenarioTests` asserts on. That sharing is the point: a run-count assertion
and a timing measurement that disagreed about which graph they ran would make
both meaningless. `GraphHarness.run` also checks each scenario's run count
before reporting, because a benchmark measures however much work it is given —
a graph that silently started recomputing twice per turn would otherwise show
up as a slower number rather than as a defect.

Numbers printed from an arbitrary developer machine are not baselines. The
recorded evidence and CI ceilings both name the pinned environment that gives
them meaning.

## Supported tool matrix

Settled by `M5-05ba` on 2026-08-17, against the upstream sources at tag
`1.36.2`. Everything here was read out of the package itself rather than
recalled, because a pin taken from memory is not a pin.

### The harness

| Fact                       | Value                                                    | Why it is written down                                                                                                                                                                                                                                                                                 |
| -------------------------- | -------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Canonical repository       | `https://github.com/ordo-one/benchmark`                  | **Renamed.** It was `ordo-one/package-benchmark` as recently as the 1.32.0 release notes. GitHub redirects, but a redirect is not a pin, and SwiftPM derives package _identity_ from the URL's last component — so the two spellings are two different identities.                                     |
| SwiftPM identity           | `benchmark`                                              | What `.product(name:package:)` must name.                                                                                                                                                                                                                                                              |
| Product                    | `.product(name: "Benchmark", package: "benchmark")`      | The library.                                                                                                                                                                                                                                                                                           |
| Build-tool plugin          | `.plugin(name: "BenchmarkPlugin", package: "benchmark")` | Required on every benchmark executable target; it generates the discovery boilerplate.                                                                                                                                                                                                                 |
| Command plugin             | `BenchmarkCommandPlugin`                                 | Vended by the dependency; no target entry needed.                                                                                                                                                                                                                                                      |
| Minimum compatible version | **1.35.0**                                               | The release that replaced jemalloc with the custom malloc interposer. Earlier versions get their malloc metrics from jemalloc, which is the Swift ≤6.2 path — and `mallocCountTotal == 0` is this project's headline threshold, so a version without the interposer is not merely older, it is silent. |
| Pinned version             | **`.exact("1.36.2")`**                                   | See below.                                                                                                                                                                                                                                                                                             |
| Upstream platform floor    | macOS 13, iOS 16                                         | Below Cog's macOS 14 floor, so it constrains nothing.                                                                                                                                                                                                                                                  |
| Upstream tools version     | `swift-tools-version: 6.3`                               | So **this package needs a Swift 6.3+ toolchain**. That does not touch the shipped library's Swift 6.2 floor: nothing depends on this package, so its toolchain requirement is not a consumer's problem.                                                                                                |

`.exact`, not `.upToNextMinor`, and the reason is upstream's own words: the
baseline representation stored in `.benchmarkBaselines` "is not stable and is
not viewed as public API and may break over time." Malloc metrics are
explicitly documented as not comparable across backends. A recorded baseline is
therefore a statement about one harness version, and a floating pin would let a
resolve quietly invalidate every threshold in the repository. Upgrading is a
deliberate, reviewed event that comes with re-baselining — which is exactly the
rule perf.md already states for the allocator path.

### Layout constraint

Benchmark sources **must** live in a directory named `Benchmarks` at the root of
the package that declares them. Here that means `swift/Benchmarks/Benchmarks/<Name>/`
— the doubled path is upstream's discovery rule, not a typo.

### Exact metric names

Read from `Sources/Benchmark/BenchmarkMetric.swift` at `1.36.2`.

| Group                        | Cases                                                                                                                                           |
| ---------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| ARC                          | `.objectAllocCount`, `.retainCount`, `.releaseCount`, `.retainReleaseDelta`                                                                     |
| Malloc (interposer backend)  | `.mallocCountTotal`, `.mallocCountSmall`, `.mallocCountLarge`, `.freeCountTotal`, `.mallocBytesCount`, `.mallocFreeDelta`, `.memoryLeakedBytes` |
| Malloc (jemalloc only, ≤6.2) | `.allocatedResidentMemory`, `.memoryLeaked` — do not use                                                                                        |
| Memory                       | `.peakMemoryResident`, `.peakMemoryResidentDelta`, `.peakMemoryVirtual`                                                                         |
| Time and work                | `.wallClock`, `.cpuUser`, `.cpuSystem`, `.cpuTotal`, `.throughput`, `.instructions`                                                             |
| Custom                       | `.custom(_:polarity:useScalingFactor:)`                                                                                                         |

Two traps worth naming. `.objectAllocCount` exists in the source but is
**missing from upstream's `Metrics.md`**; the source is authoritative. And
`.mallocCountSmall` / `.mallocCountLarge` split on jemalloc's size classes under
the old backend and on a fixed 16 KiB threshold under the interposer, so those
two are not comparable across the backend boundary even within one project.

### Baseline CLI

| Purpose                                                  | Command                                                                               |
| -------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| Run                                                      | `swift package benchmark`                                                             |
| List                                                     | `swift package benchmark list`                                                        |
| Record or update a baseline                              | `swift package --allow-writing-to-package-directory benchmark baseline update <name>` |
| Baseline versus baseline, or baseline versus a fresh run | `swift package benchmark baseline check <name> [<other>]`                             |
| Human-readable comparison                                | `swift package benchmark baseline compare <a> [<b>]`                                  |
| Absolute static thresholds                               | `swift package benchmark thresholds update\|check\|read`                              |

The absolute-threshold gate this project needs — `mallocCountTotal == 0` and
generous absolute wall-clock ceilings — is `thresholds check` at 1.36.2.
`baseline check --check-absolute` still works but upstream marks the flag
deprecated in favour of the `thresholds` verb. perf.md §9 anticipated exactly
this by saying baselines use "the CLI spelling proven by the compatibility
probe"; this is that spelling.

Writing anything into the package directory (`baseline update`, `init`) needs
`--allow-writing-to-package-directory`.

## Allocator and isolation compatibility

Settled by `M5-05bb` on 2026-08-17. Full record and raw output:
[`probes/M5-05bb-allocator-isolation.md`](./probes/M5-05bb-allocator-isolation.md).

| Question                    | Answer                                                                                   | Consequence                                                                                                  |
| --------------------------- | ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| Malloc backend on Swift 6.3 | The custom interposer, on by default                                                     | Malloc metrics are live and populated                                                                        |
| ARC counters on macOS       | Live, via `swift_runtime_set_{alloc_object,retain,release}_hook`                         | PERF-02 is measurable by the harness; `xctrace` stays for per-callsite attribution only                      |
| MainActor benchmarks        | Supported, with a structural shim (below)                                                | No dependency, flag, or unchecked conformance needed                                                         |
| MainActor hop cost          | **0 mallocs, 0 object allocs**; ~9 µs and a floor of 3 retains / 4 releases              | `mallocCountTotal == 0` is reachable; ARC and wall-clock thresholds measure against a floor rather than zero |
| VM versus bare metal        | Not applicable — `M0-05a` settled on persistent bare metal, so there is no VM to compare | Baselines are recorded on the `cog-mini` runner under the pinned Xcode, and nowhere else                     |

### The isolation shim

`Benchmark` is not `Sendable` and the benchmarks closure is nonisolated, so the
obvious spelling does not compile:

```swift
await MainActor.run { benchmark.startMeasurement() }
// error: sending 'benchmark' risks causing data races
```

The shape that works, and the rule for every benchmark here:

> Keep the graph behind a **MainActor-isolated harness type** and let the
> nonisolated benchmark body `await` into it. Nothing non-`Sendable` crosses in
> either direction — the handle stays outside, the graph stays inside, and only
> `Int`s pass between them. Read `benchmark.scaledIterations` outside and pass
> its `count` in; bracket the `await` with `startMeasurement()` /
> `stopMeasurement()` so setup stays out of the measured region.

### The silent zero, and the witness that has to exist

With `BENCHMARK_DISABLE_MALLOC_INTERPOSER=1`, the same allocating workload
reports `mallocCountTotal == 0` while `objectAllocCount` reads 12 right beside
it. `Free (total)` and `Malloc (bytes total)` disappear from the table
altogether.

**The headline threshold of this whole plan passes trivially in a misconfigured
environment.** So `M5-06` and `M5-08a` owe a witness: a benchmark that is known
to allocate, with a **non-zero** `mallocCountTotal` floor asserted on it, so a
run with the interposer off fails loudly instead of passing gloriously. A gate
that only ever asserts zeros cannot tell "no allocations" from "no
measurement".

Flipping the trait on an existing `.build` fails with
`missing required module 'MallocInterposerC'`; a clean build succeeds. Treat
backend changes as clean-build events.

### `Package.resolved` is committed here, and only here

`swift/Benchmarks/Package.resolved` is checked in: a measurement tool whose
resolve is not reproducible produces numbers that are not either. It pins the
harness at 1.36.2 and, transitively, `malloc-interposer` 1.4.0 — the backend
every malloc threshold depends on.

This is a different file from the **root** `Package.resolved`, which must never
be committed and which `docs.yml` fails the build over.

## Baselines

```console
mise run bench:baseline:update [name]   # record, with the environment beside it
mise run bench:baseline:check  [name]   # compare, refusing to cross environments
```

A benchmark number means nothing without the machine and toolchain that
produced it, so `update` writes a fingerprint — architecture, host, OS, Xcode,
Swift, harness and interposer versions, and allocator backend — next to the
baseline, and `check` refuses to compare against a baseline recorded elsewhere.
A cross-environment comparison does not produce an obviously wrong answer; it
produces a plausible one, which is worse.

`check` also runs the witness first. `perf-witness-allocating` must report a
non-zero malloc count, or every zero-allocation threshold in the suite is
passing because nothing is being measured — see the silent zero above.
Upstream thresholds are upper bounds and cannot express a floor, so the floor
lives in `tools/bench-baseline.mjs`.

Baselines live in the git-ignored `.benchmarkBaselines/`. Upstream calls the
stored format unstable, and a baseline is a statement about one machine;
numbers meant to outlive a session belong in
[`benchmarks.md`](../../docs/swift/impl/benchmarks.md) with their environment
written beside them.

## Committed CI thresholds

```console
mise run bench:thresholds:check      # run the exact and timing gates
mise run bench:thresholds:sentinel   # prove a real regression is rejected
```

The portable gate uses `swift package benchmark thresholds check` and the 13
files under `Thresholds/`: one exact allocation workload and twelve PERF-10
runtime/workload pairs. The wrapper fails before measuring if even one file is
missing or its benchmark is no longer registered. It also runs
`perf-witness-allocating` first, because a zero malloc result is evidence only
after a workload known to allocate reports nonzero. Committed thresholds
describe the specialized pool-edge shipping default, so the wrapper refuses to
apply them while any representation comparison selector chooses another build.

There is a subtle but load-bearing encoding here. Upstream compares a measured
p90 to the number in the static file, then applies the benchmark's configured
absolute _tolerance_ on both sides. It also exits nonzero when a result is far
enough below the reference, calling that an improvement. Every committed
reference is therefore **zero**, and benchmark source carries the positive
absolute tolerance. Since these metrics cannot be negative, the tolerance is a
one-sided ceiling: `0...ceiling` passes and only a value above the ceiling can
fail. PERF-06 has both reference and tolerance zero, preserving exactness.

The wall-clock ceilings are roughly three times the slower pinned p90 in each
cell. Cog's row was originally calibrated across both historical cores and
therefore remains conservative for the specialized arena default and compact
opt-out.

| Runtime           | diamond |  deep |  broad | unstable |
| ----------------- | ------: | ----: | -----: | -------: |
| Cog               |   20 ms | 10 ms |  40 ms |    10 ms |
| raw `@Observable` |    3 ms |  1 ms |   8 ms |     2 ms |
| swift-state-graph |   80 ms | 50 ms | 120 ms |    25 ms |

The sentinel command writes an impossible reference to a temporary directory,
runs the real `perf-10-observation-deep` workload through the same threshold
command, and succeeds only if the harness emits its threshold-regression
diagnostic. It never edits a committed threshold or benchmark. The wrapper
accepts both BenchmarkTool's raw exit 2 and the exit 1 to which `swift package`
can normalize a failed plugin command; the diagnostic distinguishes the
intended regression from a build or launch failure.

### Determinism — `M5-11`, settled 2026-08-17

`M5-08a` shipped a gate that failed roughly one run in six. It now passes
**32 consecutive runs**, and both causes were diagnosed rather than papered
over.

**The crash was a null ARC hook.** `kairo-diamond` exited with SIGSEGV, and the
crash report named the frame exactly:

```text
EXC_BAD_ACCESS (SIGSEGV) KERN_INVALID_ADDRESS at 0x0
  0x0
  _swift_release_hook
  _swift_release_adapter
  …
  completeTaskWithClosure
```

A call _through_ a null release hook, from the concurrency runtime finishing a
task while the harness tore its ARC hooks down between iterations. The tasks
are Cog's own and are not a leak: that benchmark builds and drops a whole
`Cogs` per iteration, each `peek` renews a `whileObserved` grace sleeper, and
dropping the context cancels them — with the cancellation completing on another
thread a moment later. A whole-scenario benchmark is therefore, by
construction, not the "single-threaded benchmark with quiescent background
allocation" upstream says its process-global counters require.

Bounded where it belongs: **`kairo-diamond` carries no counting metrics** —
wall clock, instructions, and peak memory only. Measured 0 failures in 20 runs
without them against 2 in 12 with them. The allocation benchmarks keep their
ARC and malloc metrics; their measured regions are small and quiescent, and
they never crashed once across dozens of runs.

The same non-quiescence is why the allocation benchmarks now register **first**
and the scenario benchmark last, and why `AllocationHarness.settle()` builds
its context once instead of once per iteration. Counting is process-global, so
a context torn down in one benchmark drops allocations into whichever benchmark
measures next.

**The deviation was a threshold read two ways.** Two corrections came out of
this, both worth knowing before writing another threshold:

- Upstream's `absolute` thresholds are **tolerances on the difference from a
  baseline**, not ceilings on a value. Proven by tightening a "ceiling" below
  the measured cost and watching the check stay green. Absolute ceilings use
  `thresholds check` against committed static references, as described above.
- They compare **raw sums, not the scaled per-operation figures the table
  prints**. At `scalingFactor: .kilo`, the seven mallocs a steady turn reports
  are 7,000 to a threshold, and one extra allocation per operation is a drift
  of 1,000.

That second fact makes the tolerance chooseable instead of guessed. Strays from
background allocation measured at **2 raw**, at any percentile, in roughly one
run in seven; the smallest regression that could matter is **1,000**. The
tolerance is **100** — fifty times the largest noise ever seen, a tenth of the
smallest real regression. A tolerance of zero is the tempting choice and the
wrong one: it failed about one run in seven, and a gate that cries wolf teaches
everyone to rerun.

Both directions are verified. 32 consecutive `bench:baseline:check` runs pass;
adding a single allocation per steady turn fails immediately at p0 with
`Difference Δ 1000` against `Threshold Δ 100`.

**Still open upstream.** The null-hook crash is a robustness bug in the
harness — a hook pointer read and called without guarding teardown — and it is
bounded here, not fixed. Any future benchmark whose measured region drops a
`Cogs`, spawns tasks, or otherwise leaves work on another thread should stay
off the ARC and malloc metrics for the same reason.

## Edge-layout comparison harnesses

`M6-05b` adds two persistent, quiescent PERF-09 graphs. Both roots read one
stable control and 32 data sources, keeping selector width constant while the
dependency behavior changes:

- `perf-09-edge-mostly-static` changes one source value per turn and preserves
  the complete 33-edge order;
- `perf-09-edge-high-churn` rotates through 128 sources, preserving the control
  edge and replacing the 32-edge suffix every turn.

Each graph is built and settled once, then held by one durable mechanism
reaction. The measured region neither drops a `Cogs` nor starts grace work, so
wall clock and instructions can travel beside the process-global malloc,
object-allocation, retain, and release counters.
M6-05c's same-session comparison selected the shared pool: it won the expected
mostly-static instruction count, all candidates tied on p50 wall time and
allocations, prefix arrays added ARC under churn, and inline-plus-overflow won
neither shape. `impl/benchmarks.md` records the raw comparison and rationale.
The rejected implementations and their selectors were removed once the
direction was settled; the measurements remain the reproducible decision
record.

## Runtime comparison adapters

`M6-11a` adds a common integer-named graph adapter and ports the Kairo diamond,
deep, broad, and unstable workloads through it. `M6-11b` adds the
swift-state-graph adapter to that same surface. Each workload builds and drives
the same shape for every runtime, then checks its final value and exact
computation count before the harness may report a number. This keeps an
incorrect or unexpectedly duplicated computation from hiding inside timing.

The raw adapter is deliberately literal: mutable values are `@Observable`
stored properties, computed values are ordinary uncached Swift computations,
root reads use `withObservationTracking`, and writes are ordinary property
assignments. The tracking callback is empty because the common driver pulls
the root after each write, but registration and write notification still run.
Observation does not provide a computed-value graph, cache, or batching
primitive, and adding those behind the adapter would measure a second graph
implementation rather than the standard library's registrar. The unstable
workload's repeated branch reads therefore run repeatedly under raw
Observation; its checked count records that semantic difference explicitly.

The swift-state-graph adapter uses the library's primitives directly:
`Stored<Int>`, `Computed<Int>`, `wrappedValue`, and `withGraphTransaction`.
Root reads use the same Swift Observation tracking scope as the other adapters.
The benchmark package pins swift-state-graph **0.28.0**
(`e602fcdb19342a38c135543e7228b3fd60753dc7`), the tagged release whose source
the adapter was reviewed against. The dependency and its macro toolchain remain
inside this separate package; the shipped Cog package still resolves no
dependencies.

The exact-name workloads are:

- `perf-10-cog-{diamond,deep,broad,unstable}`; and
- `perf-10-observation-{diamond,deep,broad,unstable}`; and
- `perf-10-state-graph-{diamond,deep,broad,unstable}`.

The `cog` adapter measures the specialized arena by default. Run
`mise run bench:compact` to rebuild the benchmark package with its
`CompactArena` trait and forward that public trait to Cog. The retired simple
core is preserved only in the historical report. The adapter itself uses only
public declarations, and its root reads use Cog's public Observation-tracked
subscript under the same tracking scope as the raw adapter.

## The Storefront macrobenchmark

`M10` adds the suite's one _application_ workload. Everything else here measures
a shape — a diamond, a fan, a chain, a thousand keyed states — chosen because it
isolates one cost. The Storefront measures a composed commerce session instead:
a search funnel over the whole catalog, a sixteen-policy pricing ladder per
product, keyed inventory and personalized offers, a cart whose totals depend on
two sibling async quotes, and an inventory feed that touches rows nobody is
looking at.

Its declarations, fixtures, kernels, scripted service, and interaction trace
live in **`swift/Storefront`**, a package of its own, because the SwiftUI
benchmark application in `swift/Examples/Storefront` drives the same workload
and an iOS application target cannot depend on _this_ package without resolving
the harness, the interposer, and swift-state-graph. That package depends on the
root by path and on nothing else. Read
[`swift/Storefront/README.md`](../Storefront/README.md) first.

Six cuts, and which metrics each may carry is decided entirely by `M5-11`'s
quiescence rule:

| Cut                                  | What it measures                                            | Counting metrics |
| ------------------------------------ | ----------------------------------------------------------- | ---------------- |
| `perf-15-storefront-cold`            | assembly, graph construction, first complete screen         | no               |
| `perf-15-storefront-session`         | the whole eleven-phase interaction trace                    | no               |
| `perf-15-storefront-interactions`    | settled, quiescent favorite / cart / variant / multi-write  | **yes**          |
| `perf-15-storefront-async-burst`     | one inventory burst accepted and settled                    | no               |
| `perf-15-storefront-footprint`       | what a 2,402-state keyed funnel costs to build and **hold** | **yes**          |
| `perf-15-storefront-compute-control` | the same four kernels over the same inputs, no graph        | **yes**          |

The three that say "no" build or drop a runtime and accept async completions,
which is exactly the shape the null-`swift_release_hook` crash came from. The
three that say "yes" never let a task complete inside the measured region.

### Measuring heap, and why not with resident memory

`peakMemoryResident` and `peakMemoryResidentDelta` are the only memory metrics a
non-quiescent cut may carry, and they are weak instruments: resident memory is
OS-sampled, page-granular, and a high-water mark that never comes down. Left to
a duration budget they are worse than weak — a core that runs ten times faster
completes ten times as many build-and-drop cycles in the same window, and gives
the allocator ten times as many chances to reach higher, so the column compares
throughput while looking like it compares footprint. Every cut that reports them
therefore pins `maxIterations`.

The footprint cut answers the question properly, with the interposer's exact
counters rather than a sampled one:

| Metric              | What it means here                                       |
| ------------------- | -------------------------------------------------------- |
| `mallocCountTotal`  | allocations made while building the funnel               |
| `freeCountTotal`    | allocations returned                                     |
| `mallocFreeDelta`   | allocations that **survived** — the graph's footprint    |
| `mallocBytesCount`  | gross bytes requested                                    |
| `memoryLeakedBytes` | bytes that **survived** — the closest countable "held"   |
| `storefrontStates`  | states materialized, so the columns above have a divisor |

"Survived" is a **flow balance across the measured window**, not a census of the
live heap: mallocs minus frees observed between `startMeasurement()` and
`stopMeasurement()`, in calls and in requested bytes. So a free inside the window
of something allocated before it counts against the delta and can make it
negative; something allocated inside and freed just after the window still counts
as having survived; and "requested bytes" carries no allocator rounding, no
malloc header, and no page granularity, which makes it a lower bound on resident
growth rather than a measure of it. Upstream calls the byte metric
`memoryLeakedBytes`; in a build-and-hold region the retention is intentional and
the name is a misnomer.

Read the delta columns rather than subtracting the two count columns: the
harness's table rounds to K and M, so the printed counts do not reconcile.
`--format metricP90AbsoluteThresholds --path stdout` prints exact p90 integers
when you need them to.

For a steady-state region such as `-interactions`, both delta columns should
read **zero**; a non-zero one is an interaction that grows the heap every time a
shopper performs it. For a build region such as `-footprint`, the delta columns
_are_ the answer.

That cut never releases a context. Releasing one between iterations would drop
thousands of states and cancel their grace sleepers, and the frees would land
inside the next iteration's measured region — the exact misattribution `M5-11`
recorded. `maxIterations` is 3 because each retained context is a whole
standard-profile graph, and because these are exact counts rather than a sampled
distribution: agreement from p0 to p100 is the result.

One consequence worth knowing before reading a number: the footprint cut's
retained graphs raise the process's resident baseline for every cut registered
after it. `peakMemoryResidentDelta` is a delta and survives that;
`peakMemoryResident` does not, so read the absolute column only from a run where
the timing cuts were filtered on their own.

The interaction cut deliberately excludes query changes. Typing materializes new
rows, new rows start inventory and offer requests, and a measured region that
starts async work is not a region process-global counters may be attached to.
Search cost is measured by the session cut, on wall clock alone.

Its retained state does not reset between samples, so neither does its operation
sequence. Before counters are armed, one complete viewport lap materializes
every keyed source and stabilizes the cart and favorite collections. A monotonic
ordinal then rotates across the visible products, alternates each product's cart
quantity between one and two on successive laps, advances its variant, toggles
its favorite, and assigns a new view rank. After the timer stops, the harness
replays that exact ordinal range into the plain Storefront shadow and compares
the rendered checksum. This prevents the cut from quietly becoming a loop of
equality-gated writes after its first sample.

The compute-only control is reported **beside** the application cuts and never
subtracted from them. It is also the check on the core comparison: it contains
no graph, so swapping cores must not move it. Its cart products are priced
directly through the same sixteen-policy kernel rather than looked up in the
search-candidate price table; the two product sets need not overlap. A committed
semantic checksum test covers those prices along with search, ranking,
promotions, stock state, and recommendations.

The correctness verifier is outside every reported timing. Cold and session
drivers reuse immutable fixture-derived shadow storage prepared before
`startMeasurement()`, suppress phase checkpoint evaluation until the timer is
stopped, and then require the final visible identifiers, rendered checksum, and
zero-outstanding-request ledger to agree. The burst cut likewise chooses its
demanded identifiers before timing and advances its shadow after timing. The
package correctness suite runs the detailed phase-by-phase checks.

```console
mise run bench --filter 'perf-15-storefront-.*'
mise run bench:compact --filter 'perf-15-storefront-.*'
mise run test:storefront        # the correctness gate the numbers rest on
```

Nothing here is gated. There are no committed threshold files for `perf-15`,
and `tools/bench-baseline.mjs` names none, because these are first measurements
on one host and a threshold with no repeated pinned-CI history behind it is a
guess. `impl/benchmarks.md` records the numbers, the environment, the workload's exact
shape, and what it does not cover.

## What is coming

The comparison and its CI gate are complete. The specialized arena now ships by
default, while these shared workloads and their ceilings continue to cover its
compact opt-out.

Per-callsite ARC attribution stays a manual `xcrun xctrace` workflow, documented
here when a count moves and the question becomes which line moved it.
