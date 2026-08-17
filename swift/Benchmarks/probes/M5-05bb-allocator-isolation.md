# Probe: allocator backend, ARC counters, and MainActor isolation

`M5-05bb`, run 2026-08-17. This is the log the decision rests on, kept because
a compatibility table with no measurements behind it is a guess with a
tablecloth on.

## Environment

|               |                                                                                                        |
| ------------- | ------------------------------------------------------------------------------------------------------ |
| Host          | `mactop` — Apple Silicon, 12 cores, 24 GB, Darwin 25.4.0 (`xnu-12377.101.15~1`, `RELEASE_ARM64_T6041`) |
| Xcode         | 26.4 (17E192)                                                                                          |
| Swift         | 6.3 (`swiftlang-6.3.0.123.5`), target `arm64-apple-macosx26.0`                                         |
| Harness       | `ordo-one/benchmark`, `.exact("1.36.2")` (pinned by `M5-05ba`)                                         |
| Transitive    | `malloc-interposer` 1.4.0                                                                              |
| Configuration | release                                                                                                |

**This is not the runner.** The pinned CI environment is the `cog-mini`
self-hosted Mac mini on Xcode 26.6. Every qualitative answer below — which
backend is active, whether ARC hooks fire, whether a MainActor benchmark
compiles — is a property of the toolchain and package, and 26.4 and 26.6 both
ship Swift 6.3. The _numbers_ are not baselines and must not be treated as any;
baselines are recorded on the mini by `M5-08a`.

## The probe

Three benchmarks, all metrics enabled, 50 samples each, release:

```swift
@MainActor
enum ProbeHarness {
  static var cogs: Cogs?
  static var sourceCog = ManualCog<Int>(0, name: "probe.source")
  static var derivedCog = Cog<Int>({ c in c[ProbeHarness.sourceCog] + 1 }, name: "probe.derived")

  static func setUp() {
    let context = Cogs.forTesting()
    blackHole(context.peek(derivedCog))
    cogs = context
  }

  static func runTurns(_ count: Int) {
    guard let cogs else { return }
    for iteration in 1...max(count, 1) {
      cogs.commit("probe.turn") { c in c[sourceCog] = iteration }
      blackHole(cogs.peek(derivedCog))
    }
  }

  static func noop() {}
  static func runScenario() {
    blackHole(CogScenario.kairoDiamond(width: 5, turns: 10).run(in: Cogs.forTesting()).actualRuns)
  }
}

let benchmarks: @Sendable () -> Void = {
  Benchmark("probe-a-hop-only") { benchmark in
    benchmark.startMeasurement()
    for _ in benchmark.scaledIterations { await ProbeHarness.noop() }
    benchmark.stopMeasurement()
  }

  Benchmark("probe-b-steady-turns") { benchmark in
    await ProbeHarness.setUp()
    let count = benchmark.scaledIterations.count
    benchmark.startMeasurement()
    await ProbeHarness.runTurns(count)
    benchmark.stopMeasurement()
  }

  Benchmark("probe-c-whole-scenario") { benchmark in
    await ProbeHarness.runScenario()
  }
}
```

## Finding 1 — the isolation shim, and why the obvious spelling does not compile

The first attempt wrote the natural thing:

```swift
Benchmark("x") { benchmark in
  await MainActor.run {
    benchmark.startMeasurement()   // ← error
    ...
  }
}
```

```text
error: sending 'benchmark' risks causing data races [#SendingRisksDataRace]
```

`Benchmark` is not `Sendable`, and the benchmark closure is `@Sendable` and
nonisolated, so the measurement handle cannot cross into a MainActor region.
That is the whole isolation problem, and it has a shape rather than a
workaround:

> **Keep the graph behind a MainActor-isolated harness type and let the
> nonisolated benchmark body `await` into it.** Nothing non-`Sendable` crosses
> in either direction — the handle stays outside, the graph stays inside, and
> only `Int`s pass between them.

`benchmark.scaledIterations` is read outside the isolated region and its
`count` passed in. `startMeasurement()` / `stopMeasurement()` bracket the
`await`, so setup stays out of the measured region.

This is a shim in the sense `M5-05c` means: a small structural rule, not a
dependency or a compiler flag. No `nonisolated(unsafe)`, no
`assumeIsolated`, no unchecked `Sendable` conformance.

## Finding 2 — the MainActor hop is free, in the metrics that gate

`probe-a-hop-only`, one `await` into the MainActor per scaled iteration and
nothing else:

```text
│ Malloc (total) *          │ 0 │ 0 │ 0 │ 0 │ 0 │ 0 │ 0 │ 50 │
│ Malloc (bytes total) *    │ 0 │ 0 │ 0 │ 0 │ 0 │ 0 │ 0 │ 50 │
│ Free (total) *            │ 0 │ 0 │ 0 │ 0 │ 0 │ 0 │ 0 │ 50 │
│ Object allocs *           │ 0 │ 0 │ 0 │ 0 │ 0 │ 0 │ 0 │ 50 │
│ Retains *                 │ 3 │ 3 │ 3 │ 3 │ 3 │ 3 │ 3 │ 50 │
│ Releases *                │ 4 │ 4 │ 4 │ 4 │ 4 │ 4 │ 4 │ 50 │
│ Time (wall clock) (ns) *  │ 7917 │ 8959 │ 9423 │ 9839 │ 10543 │ 16583 │ 16583 │ 50 │
```

**Zero mallocs and zero object allocations for the hop itself.** This is the
result PERF-01 and PERF-06 depend on: `mallocCountTotal == 0` is reachable
through the shim, so the threshold measures Cog rather than the harness.

The hop is not free in _time_ — roughly 9 µs at p50 for the loop — so wall-clock
thresholds must either amortize a large `count` inside one hop, or accept a
fixed offset. Amortizing is the better answer and is what `probe-b` does.

A constant three retains and four releases leak into the region from the
continuation machinery, so `retainReleaseDelta` is 1 rather than 0 even for an
empty body. PERF-02 must measure ARC _deltas against this floor_, not absolute
zero.

## Finding 3 — ARC counters work on macOS

`objectAllocCount`, `retainCount`, `releaseCount`, and `retainReleaseDelta` all
report on this host. That was the open question `M5-05ba` handed over: upstream
collects ARC two different ways, and only the Linux path uses the runtime
interposer. Everywhere else — this project included — it installs
`swift_runtime_set_{alloc_object,retain,release}_hook`, and whether those hooks
are live in Apple's shipped runtime could only be answered by running it.

They are. `probe-c-whole-scenario` reports 278 object allocs, 3,639 retains and
5,519 releases for one small Kairo diamond, and `probe-a` reports 0/3/4 for an
empty body — a floor, not silence.

So PERF-02 can be measured by the harness. The manual `xcrun xctrace` workflow
stays what perf.md says it is: _per-callsite attribution_, for when a count has
moved and the question becomes which line moved it.

## Finding 4 — the malloc backend, and a silent zero worth guarding

The interposer is on by default and it works. `probe-b-steady-turns` reports 16
to 26 mallocs and ~3.5 KB per measured region, with `Free (total)` and
`Malloc (bytes total)` populated.

Disabling it is where the trap is. With `BENCHMARK_DISABLE_MALLOC_INTERPOSER=1`
and a clean build, the _same workload_ reports:

```text
│ Malloc (total) *   │ 0  │ 0  │ 0  │ 0  │ 0  │ 0  │ 0  │ 50 │
│ Object allocs *    │ 11 │ 12 │ 12 │ 12 │ 12 │ 12 │ 12 │ 50 │
```

`Free (total)` and `Malloc (bytes total)` vanish from the table entirely, and
`Malloc (total)` reads **zero while the workload demonstrably allocates** —
`objectAllocCount` is 12 right beside it.

> **A `mallocCountTotal == 0` threshold passes trivially when the interposer is
> off.** The headline gate of the whole benchmark plan can be satisfied by a
> misconfigured environment rather than by correct code.

So the gate needs a witness. `M5-06` and `M5-08a` must include a benchmark that
is _known_ to allocate and assert a non-zero `mallocCountTotal` floor on it,
so a run with the interposer disabled fails loudly instead of passing
gloriously. A CI job that only ever asserts zeros cannot distinguish "no
allocations" from "no measurement".

One more rough edge: flipping the trait on an existing `.build` fails with
`missing required module 'MallocInterposerC'` — the Swift half of the
interposer still imports the C half that the trait removed. A clean build
succeeds. Treat backend changes as clean-build events.

## Finding 5 — VM versus bare metal does not apply

The task asks for VM-versus-bare-metal noise on the mini. There is nothing to
compare: `M0-05a` settled the runner topology on **persistent bare metal** on
2026-08-10, and Tart-based ephemeral VMs are a recorded deferred upgrade rather
than the current topology, because no macOS ephemeral-runner orchestrator
shipped a release in 2026. No VM exists on the mini to measure.

The decision that follows: **baselines are recorded on the bare-metal mini
under the pinned Xcode**, and nowhere else. If the deferred Tart upgrade is ever
taken, this probe must be redone before any baseline is trusted, because a
hypervisor between the benchmark and the timer is exactly the kind of change
that moves wall-clock percentiles without moving code.

## Reproducing

The probe target was deliberately not committed — `M5-05c` owns adding the
dependency. To rerun: add
`.package(url: "https://github.com/ordo-one/benchmark", exact: "1.36.2")` to
`swift/Benchmarks/Package.swift`, add an executable target at
`swift/Benchmarks/Benchmarks/CogProbe/` with the `Benchmark` product and the
`BenchmarkPlugin` plugin, paste the source above, and run
`swift package benchmark --target CogProbe`.
