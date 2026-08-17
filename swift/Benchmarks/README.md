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

`mise run bench` wraps it from the repository root once `M5-08b` adds it. The
plugin always builds release; a debug measurement of a graph library measures
the optimizer's absence.

## What is here today

One target, `CogGraph`, with one benchmark over the shared Kairo diamond. It
exists to prove the whole path works end to end — pinned harness, isolation
shim, shared scenarios, release build — and it carries **no thresholds**.
`M5-06` and `M5-07a`–`M5-07d` add those one measured result at a time, because a
threshold with no measurement behind it is a guess that fails at the worst
moment.

Benchmarks drive the scenarios from `_CogScenarios`, the same values
`CogScenarioTests` asserts on. That sharing is the point: a run-count assertion
and a timing measurement that disagreed about which graph they ran would make
both meaningless. `GraphHarness.run` also checks each scenario's run count
before reporting, because a benchmark measures however much work it is given —
a graph that silently started recomputing twice per turn would otherwise show
up as a slower number rather than as a defect.

Numbers printed from a developer machine are not baselines. Baselines are
recorded on the pinned runner by `M5-08a`.

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
be committed and which `swift-docs.yml` fails the build over.

## Baselines

```console
mise run bench:baseline:update [name]   # record, with the environment beside it
mise run bench:baseline:check  [name]   # compare, refusing to cross environments
```

A benchmark number means nothing without the machine and toolchain that
produced it, so `update` writes a fingerprint — architecture, host, OS, Xcode,
Swift, harness and interposer versions, allocator backend — next to the
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
[`perf.md`](../../docs/swift/design/perf.md) §9.6 with their environment
written beside them.

### Known flakiness — `M5-11`

Two intermittent failures were measured while wiring this up, and neither is
fixed yet:

- **`kairo-diamond` crashes the harness roughly one run in six** under full
  instrumentation — about 2,200 mallocs per iteration at a couple of thousand
  iterations a second, exiting with signal 11. The same scenario runs 20,000
  iterations clean outside the harness, and the low-allocation `perf-` family
  never crashes, so the finger points at instrumentation under a high
  allocation rate rather than at Cog.
- **`perf-06-value-reference` occasionally reports a malloc deviation** against
  its zero ceiling. Upstream documents malloc counting as process-global and
  "only reliable for single-threaded benchmarks with quiescent background
  allocation", which would explain it.

The gated baseline is therefore filtered to the `perf-` family as a stopgap: a
gate that fails one run in six is not a gate. `M5-11` owns diagnosing both and
either fixing them or bounding them explicitly, and `M5-10` cannot close over
it.

## What is coming

| Task               | Adds                                                                                          |
| ------------------ | --------------------------------------------------------------------------------------------- |
| `M5-05c`           | the pinned dependency, the selected allocator configuration, and one real MainActor benchmark |
| `M5-06`            | zero-allocation steady-turn and `box[key]` creation benchmarks                                |
| `M5-07a`–`M5-07d`  | ARC traffic, peak memory, boundary-object counts, pinned-key notice traffic                   |
| `M5-08a`, `M5-08b` | pinned-environment baselines, `mise run bench`, and the non-gating `bench-build` CI job       |

Per-callsite ARC attribution stays a manual `xcrun xctrace` workflow, documented
here when `M5-07a` establishes it.
