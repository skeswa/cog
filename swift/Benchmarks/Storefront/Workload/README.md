# The Storefront workload

This is the runtime-neutral foundation of the Storefront macrobenchmark. It is
a separate SwiftPM package named `cog-storefront-workload`, with no package
dependencies and one library target that depends on nothing at all—not even
Cog.

That zero-dependency boundary lets four different state-management runtimes run
the identical commerce session. The headless cuts in
[`Runner/Benchmarks/Storefront`](../../Runner/Benchmarks/Storefront/), the
SwiftUI app in [`Apps/Cog`](../Apps/Cog/), and every runtime package share the
same domain model, deterministic fixtures, heavy kernels, scripted service,
shadow model, and interaction trace.

## Package boundary

| Target               | What it owns                                                                                                                                                                                                                   | Depends on         |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------ |
| `StorefrontWorkload` | the model, profiles, fixtures, pricing ladder, heavy kernels, scripted service, shadow model, sink, hold set, phase and checkpoint vocabulary, `StorefrontRuntime` protocol, and generic session driver and eleven-phase trace | **nothing at all** |

The four implementations live in sibling packages under `Runtimes/`. Keeping
them out of this package makes dependency neutrality mechanically visible in
`Package.swift`, not merely a target-level convention:

```text
StorefrontWorkload
  ├──> CogRuntime       ──> cog
  ├──> Observation     (raw and memo targets)
  └──> StateGraph      ──> swift-state-graph 0.28.0

all four runtime products
  ├──> Verification    (correctness only)
  └──> Runner          (measurement only)

CogRuntime + StorefrontWorkload
  └──> Apps/Cog        (SwiftUI/XCTest driver)
```

No arrow points from a Storefront package back to the runner. An application
can therefore resolve the workload and its chosen runtime without resolving
the benchmark harness, allocator interposer, or an unrelated runtime library.

## What "representative" means here, and what it does not

This is a **representative workload v1**. There is no such thing as a typical
application without production telemetry, so the scale is an explicit,
configurable, asserted choice rather than a claim about real apps.
`StorefrontProfile` holds every number, `StorefrontWorkloadShapeTests` checks
them (and `StorefrontShapeTests` censuses the Cog declaration count), and
[`impl/perf.md`](../../../../docs/swift/impl/perf.md) records what the workload
covers **and what it does not**.

Three profiles, three questions:

| Profile    | Question                                        | Where it runs                                   |
| ---------- | ----------------------------------------------- | ----------------------------------------------- |
| `smoke`    | is it correct, and does the screen come up?     | this package's tests, and the simulator UI runs |
| `standard` | what does a representative session cost?        | the reported benchmark cuts                     |
| `stress`   | does it still behave at several times the size? | local and nightly only, never reported          |

## What is deterministic, and how

Everything. There is no network, no `Date`, no `Task.sleep`, no unseeded
randomness, and no `Foundation` import in the target — a fixture that
folded case or trimmed whitespace by the host's locale rules would make the
workload's inputs depend on device settings.

Asynchrony is scripted rather than timed. Every async selector registers its
semantic request synchronously before returning work to Cog. `StorefrontScript`
then moves that request from a lock-backed **scheduled** ledger to its actor's
**started** and suspended ledgers. The driver can therefore drain work selected
by the graph even when the task has not reached the service actor yet; an empty
drain proves there is neither scheduled nor suspended work, rather than merely
winning a scheduler race.

The driver releases responses by name in a deliberately out-of-order sequence.
Superseded requests stay suspended instead of resuming on cancellation, which
keeps the headless driver free of races with the runtime's own one-shot
publish-or-discard signal — and makes a stale completion something the driver
can schedule on purpose rather than hope for. That signal is a runtime
requirement rather than something the script can supply: a released
continuation resumes, and the script's outstanding count drops, _before_ the
runtime has decided anything.

## Running it

```console
mise run test:storefront          # this neutral package's correctness and shape suites
mise run test:storefront-cog      # the Cog implementation and declaration census
mise run test:storefront-all      # all four runtimes plus the agreement gate
mise run bench --filter 'perf-15-storefront-.*'
mise run bench:compact --filter 'perf-15-storefront-.*'
mise run bench --filter 'perf-16-storefront-.*'   # the same workload, four runtimes

# read the absolute resident-memory column only from a run of the timing cuts
# alone: the footprint cut retains its graphs, which raises the baseline.
mise run bench --filter 'perf-15-storefront-(cold|session|async-burst)'
```

The correctness suite is the gate every reported number depends on. It runs the
trace with every phase checkpoint enabled. Reported samples disable those
deliberately expensive checks while their timer is running, then compare the
sample's final visible identifiers and rendered checksum with the independent
shadow and require exactly zero outstanding requests after the timer stops.

The same boundary applies to the specialized cuts. Inventory-burst identifiers
are snapshotted before timing and their shadow generations advance afterward.
The retained interaction cut primes one complete viewport lap before counters
are armed, then uses one monotonic ordinal across warmups and samples, alternates
each product's quantity between one and two, advances its variant every viewport
lap, and replays the exact measured operations into the shadow after timing. The
compute-only control's stable signature covers search, ranking, directly priced
cart lines, promotions, and recommendations.

## The eleven-phase trace

`StorefrontSessionDriver<Runtime>.runStandardTrace()` performs one fixed story —
bootstrap, root data, initial row data, scroll, search, filters, cart, detail,
checkout, inventory burst, teardown — and records a `StorefrontCheckpoint` at
every claim when checkpoint recording is enabled.

The driver is generic over `StorefrontRuntime`, and that is what makes the
comparison a comparison: every runtime runs this trace rather than one like it.

A smoke run of the standard trace records forty-one checkpoints. Eleven of them
take their expected value from the runtime's own `StorefrontRuntimeSemantics`:
nine are claims about _invalidation_ — how many held-observer runs a settled
turn owes — and two are claims about how much asynchronous work an offscreen
half is allowed to start. A runtime declares those numbers for itself and is
then held to them. The other thirty admit no per-runtime variation at all:
identity, checksum, money, promotion plan, request quiescence. Declaring a
convenient number buys nothing, because those thirty and `requireSettledOutput`
are the same for everyone.

Two of that thirty turn on a declared _capability_ rather than a declared
number — the per-generation refresh handle and the lifetime release proof — so a
runtime that does not make those claims records an explicit skip instead of a
silent gap. Twenty-eight checkpoints are therefore asserted identically and
unconditionally by every runtime.

Those are counts of recorded checkpoint rows, not of distinct claims written in
the trace: three of the eleven are one favorite-toggle claim repeated once per
favorited product, and two are one offscreen-work claim made before and after
the onscreen half is released.

The multi-source verbs — `applyBrowseFilters`, `openProduct`, `addToCart`,
`setCartQuantity`, `publishInventoryBurst` — are single protocol requirements
rather than a batching primitive the trace drives. The trace has no access to
the individual sources, so it cannot split one of those actions into several
settlements even by mistake; a _port_ that split one internally is caught by the
one-run checkpoint on the very next line.

Expectations come from
`StorefrontWorld`, a shadow model updated from the profile and the events the
driver issued, never from a number copied out of a passing run. Benchmark cuts
prepare its catalog, indexes, and lookup dictionaries before starting their
timers; the runtime under measurement still obtains its own catalog through the
scripted service.

The `perf-15` figures this package produces, the four-runtime `perf-16` tables
the same workload produces through the other three ports, and what neither
establishes are recorded in
[`docs/swift/impl/perf.md`](../../../../docs/swift/impl/perf.md#storefront-macrobenchmark).
