# The Storefront workload

A **separate SwiftPM package**, and — like `swift/Benchmarks` and `swift/Lint` —
that separation is the whole design of this directory. It sits _inside_
`swift/Benchmarks/`, which is a filesystem fact and not a dependency fact: what
keeps an iOS application clear of the harness is that this is its own package,
not that it lives in its own corner of the tree.

The Storefront is one realistic commerce graph shared by two very different
drivers:

- the headless benchmark cuts in
  [`swift/Benchmarks`](../../../Benchmarks/CogGraph/StorefrontBenchmarks.swift),
  which produce stable, Cog-specific measurements; and
- the SwiftUI benchmark application in
  [`Apps/Cog`](../Apps/Cog), which XCTest drives
  through a real interface.

They share the state declarations, the fixtures, the domain operations, the
deterministic async service, and the interaction trace. That sharing is the
point: two drivers exercising two similar-looking workloads would let a UI
result and a headless result disagree without either being wrong.

## Two targets, and why the neutral one depends on nothing

| Target               | What is in it                                                                                                                                                                                                                                                                     | Depends on                                |
| -------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------- |
| `StorefrontWorkload` | the model, the profiles, the fixtures, the pricing ladder, the heavy kernels, the scripted service, the shadow model, the sink, the hold set, the phase names, the checkpoint vocabulary, the `StorefrontRuntime` protocol, and the generic session driver and eleven-phase trace | **nothing at all**                        |
| `CogStorefront`      | the 53 Cog declarations, the `CogOps` verbs, the mechanism, and the `CogStorefrontRuntime` adapter                                                                                                                                                                                | `StorefrontWorkload`, `Cog`, `CogTesting` |

`StorefrontWorkload` having _no_ dependency — not even on Cog — is the
load-bearing property, not a tidiness preference. It is what makes it possible
to hand a state-management runtime with no Cog in it the identical shopping
session rather than a similar one, and it is mechanically checkable with
`swift package describe --type json`. A forked workload would be a comparison
of two different sessions.

## Why it is not part of the `cog-benchmarks` package

Read that heading carefully: the _package_, not the directory. This directory is
inside `swift/Benchmarks/`, so any claim that the workload lives somewhere else
would be plainly false — and it was never the argument.

The argument is that **an iOS application cannot depend on `cog-benchmarks`**.
That package depends on the ordo-one benchmark harness, its malloc interposer,
and swift-state-graph; SwiftPM hands a package's dependencies to everyone who
resolves it, so an application target that consumed a library product from it
would resolve all three. This is a package of its own, depending on the root Cog
package by path and on **nothing else**, for the same reason the root itself
resolves with no dependencies at all.

So this directory being nested inside another package's directory is a
**filesystem fact, not a dependency fact**, and it must never be read as an
invitation to merge the two. Folding `cog-storefront` into `cog-benchmarks` —
by making it a target there, or by giving a `cog-benchmarks` target a `path:`
that reaches into `Macro/` — would break the SwiftUI benchmark applications in
`Apps/`, which link this workload and must not resolve a benchmark harness, an
allocator interposer, or swift-state-graph to do it. The sibling
[`Runtimes`](../Runtimes/README.md) and [`StateGraph`](../StateGraph/README.md)
packages are nested for the same reason and carry the same prohibition.

The arrows only ever point down or to the right, and they are what the nesting
is not:

```text
                         cog (root, zero dependencies)
                              ^
                              |
   ┌──────────────────────────┴───────────────────────────────────────┐
   │  cog-storefront   —   swift/Benchmarks/Macro/Storefront/Workload │
   │                                                                  │
   │   StorefrontWorkload  ......  zero dependencies                  │
   │        ^        ^        ^        ^                              │
   │        |        |        |        |                              │
   │   CogStorefront │        │        │                              │
   │   (Cog, CogTesting)      │        │                              │
   └────────^────────┼────────┼────────┼──────────────────────────────┘
            |        |        |        |
            |        |        |        └──── cog-storefront-state-graph
            |        |        |               swift/Benchmarks/Macro/Storefront/StateGraph
            |        |        |                 └── swift-state-graph 0.28.0
            |        |        |
            |        |        └──────────── cog-storefront-runtimes
            |        |                       swift/Benchmarks/Macro/Storefront/Runtimes
            |        |                         StorefrontObservationMemo
            |        └───────────────────── cog-storefront-runtimes
            |                                 StorefrontObservationRaw
            |
            └── Storefront.app (Xcode, iOS)
                 swift/Benchmarks/Macro/Storefront/Apps/Cog
                 [+ sibling comparison apps under Apps/, later phase]

   cog-benchmarks        swift/Benchmarks
   (harness, malloc interposer, swift-state-graph)
        │
        ├──> cog                        (path ../..)
        ├──> cog-storefront             (path Macro/Storefront/Workload)
        ├──> cog-storefront-runtimes    (path Macro/Storefront/Runtimes)
        └──> cog-storefront-state-graph (path Macro/Storefront/StateGraph)

   Three of those boxes sit *inside* the fourth box's directory. They are still
   four packages: the nesting is a filesystem fact, and the arrows are the
   dependency facts.
```

Nothing points back into the root, and nothing an iOS application target links
reaches the harness, the interposer, or swift-state-graph unless that specific
application is the state-graph comparison app. The three comparison-runtime
targets exist today, and they exist only because `StorefrontWorkload` sits at the
bottom of that picture depending on nothing at all.

## What "representative" means here, and what it does not

This is a **representative workload v1**. There is no such thing as a typical
application without production telemetry, so the scale is an explicit,
configurable, asserted choice rather than a claim about real apps.
`StorefrontProfile` holds every number, `StorefrontWorkloadShapeTests` checks
them (and `StorefrontShapeTests` censuses the Cog declaration count), and
[`impl/perf.md`](../../../../../docs/swift/impl/perf.md) records what the workload
covers **and what it does not**.

Three profiles, three questions:

| Profile    | Question                                        | Where it runs                                   |
| ---------- | ----------------------------------------------- | ----------------------------------------------- |
| `smoke`    | is it correct, and does the screen come up?     | this package's tests, and the simulator UI runs |
| `standard` | what does a representative session cost?        | the reported benchmark cuts                     |
| `stress`   | does it still behave at several times the size? | local and nightly only, never reported          |

## What is deterministic, and how

Everything. There is no network, no `Date`, no `Task.sleep`, no unseeded
randomness, and no `Foundation` import in either target — a fixture that
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
mise run test:storefront          # this package's correctness and shape suites
mise run test:storefront-all      # and the other three ports, plus the agreement gate
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
[`docs/swift/impl/perf.md`](../../../../../docs/swift/impl/perf.md#storefront-macrobenchmark).
