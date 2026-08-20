# The Storefront workload

A **separate SwiftPM package**, and — like `swift/Benchmarks` and `swift/Lint` —
that separation is the whole design of this directory.

The Storefront is one realistic commerce graph shared by two very different
drivers:

- the headless benchmark cuts in
  [`swift/Benchmarks`](../Benchmarks/Benchmarks/CogGraph/StorefrontBenchmarks.swift),
  which produce stable, Cog-specific measurements; and
- the SwiftUI benchmark application in
  [`swift/Examples/Storefront`](../Examples/Storefront), which XCTest drives
  through a real interface.

They share the state declarations, the fixtures, the domain operations, the
deterministic async service, and the interaction trace. That sharing is the
point: two drivers exercising two similar-looking workloads would let a UI
result and a headless result disagree without either being wrong.

## Why it is not part of `swift/Benchmarks`

Because an iOS application cannot depend on that package. `swift/Benchmarks`
depends on the ordo-one benchmark harness, its malloc interposer, and
swift-state-graph; an application target that consumed a library product from it
would resolve all three. This package depends on the root Cog package by path
and on **nothing else**, for the same reason the root itself resolves with no
dependencies at all.

The arrows only ever point one way:

```text
cog (root, zero dependencies)
  ^                    ^
  |                    |
cog-storefront   <---- cog-benchmarks (harness, interposer, state-graph)
  ^
  |
Storefront.app (Xcode, iOS)
```

## What "representative" means here, and what it does not

This is a **representative workload v1**. There is no such thing as a typical
application without production telemetry, so the scale is an explicit,
configurable, asserted choice rather than a claim about real apps.
`StorefrontProfile` holds every number, `StorefrontShapeTests` checks them, and
[`perf.md`](../../docs/swift/design/perf.md) §9.6 records what the workload
covers **and what it does not**.

Three profiles, three questions:

| Profile    | Question                                        | Where it runs                                   |
| ---------- | ----------------------------------------------- | ----------------------------------------------- |
| `smoke`    | is it correct, and does the screen come up?     | this package's tests, and the simulator UI runs |
| `standard` | what does a representative session cost?        | the reported benchmark cuts                     |
| `stress`   | does it still behave at several times the size? | local and nightly only, never reported          |

## What is deterministic, and how

Everything. There is no network, no `Date`, no `Task.sleep`, no unseeded
randomness, and no `Foundation` import anywhere in this target — a fixture that
folded case or trimmed whitespace by the host's locale rules would make the
workload's inputs depend on device settings.

Asynchrony is scripted rather than timed. `StorefrontScript` records every
request under a semantic identity, lets a driver await the exact set that has
**started**, and releases responses by name in a deliberately out-of-order
sequence. Superseded requests stay suspended instead of resuming on
cancellation, which is what keeps the headless driver free of races with Cog's
one-shot async-completion acknowledgement — and what makes a stale completion
something the driver can schedule on purpose rather than hope for.

## Running it

```console
mise run test:storefront          # this package's correctness and shape suites
mise run bench --filter 'perf-15-storefront-.*'
COG_TEST_CORE=arena mise run bench --filter 'perf-15-storefront-.*'

# read the absolute resident-memory column only from a run of the timing cuts
# alone: the footprint cut retains its graphs, which raises the baseline.
mise run bench --filter 'perf-15-storefront-(cold|session|async-burst)'
```

The correctness suite is the gate every reported number depends on: each
benchmark cut calls `requireCheckpointsHold()` before it reports anything, so a
workload that computed the wrong answer traps instead of producing a timing.

## The eleven-phase trace

`StorefrontSessionDriver.runStandardTrace()` performs one fixed story —
bootstrap, root data, initial row data, scroll, search, filters, cart, detail,
checkout, inventory burst, teardown — and records a `StorefrontCheckpoint` at
every claim. Expectations come from `StorefrontWorld`, a shadow model
recomputed from the profile and the events the driver issued, never from a
number copied out of a passing run.
