# The Storefront macrobenchmark

Every other benchmark in this repository measures a **shape** — a diamond, a
fan, a chain, a thousand keyed states — chosen because it isolates exactly one
cost. The Storefront measures an **application**: one composed commerce session,
run end to end, by four different state-management runtimes.

The question it exists to answer is not "how fast is a turn." It is: given a
realistic screen with a search funnel over a whole catalog, a sixteen-policy
pricing ladder per product, keyed inventory and personalized offers, a cart whose
totals depend on two sibling asynchronous quotes, and an inventory feed that
touches rows nobody is looking at — **what does Cog's machinery cost, and what
does it buy, against the alternatives a real team would actually consider?**

Answering that honestly is the entire design of this directory, and almost every
structural decision here exists to stop the comparison from quietly becoming
dishonest.

## What lives here

```text
swift/Benchmarks/Storefront/
  README.md                 this file
  Workload/                 cog-storefront-workload, with no dependencies
  Runtimes/
    CogRuntime/             cog-storefront, the Cog port
    Observation/            cog-storefront-observation, two plain-Swift ports
    StateGraph/             cog-storefront-state-graph, plus API probes
  Verification/             test-only cross-runtime agreement package
  Apps/
    Cog/                    the SwiftUI benchmark application driving the Cog port
```

Each leaf with a `Package.swift` is an independent SwiftPM package. This
structure makes the dependency direction visible: runtime packages depend on
the neutral workload, the test-only verification package depends on all four
runtimes, and the benchmark runner depends on the packages it measures. No
Storefront package depends on the runner, so applications never resolve the
ordo-one harness or malloc interposer.

The executable benchmark target for this suite lives next door in
`swift/Benchmarks/Runner/Benchmarks/Storefront/`. Its immediate parent must keep
the literal name `Benchmarks`; that doubled name is the upstream harness's hard
discovery rule.

## The four runtimes, and what each one is for

Each runtime declares a `slug`, which is the middle of a benchmark result name:
`perf-16-storefront-<slug>-<cut>`.

| Slug               | Package                      | What it is for                                                                                                                                                                |
| ------------------ | ---------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `cog`              | `cog-storefront`             | The subject. The workload declared the Cog way: sources, automatic chains, keyed selectors, async policies, and one assembly mechanism.                                       |
| `observation-raw`  | `cog-storefront-observation` | **The hardware floor.** Plain `@Observable` with no cache, no memo, no dirty bit, no dependency edge. Every derived value recomputed on every read.                           |
| `observation-memo` | `cog-storefront-observation` | **The realistic competitor.** Honest hand-written memoization over the same primitives: seven caches and one file that says by hand what each write clears.                   |
| `state-graph`      | `cog-storefront-state-graph` | **The closest library.** The same workload over [swift-state-graph](https://github.com/VergeGroup/swift-state-graph) `Stored` and `Computed` nodes, pinned `exact: "0.28.0"`. |

The floor and the competitor are the two halves of a fair reading. Against
`observation-raw` alone, any caching library looks like a triumph; the number
that matters is Cog against `observation-memo`, because that is what a competent
team ships when it has `@Observable`, cares about performance, and no reactive
library. `observation-raw` is what tells you how much of the remaining gap is
caching at all rather than Cog specifically.

The two `@Observable` ports are separate **targets** for the same reason the
packages are separate: it makes it a compile error for the floor to reach the
memo port's cache, which is the single most likely way this comparison could go
wrong. The state-graph port is a separate **package** because SwiftPM hands a
package's dependencies to everyone who resolves it, and an `@Observable`
comparison application must not resolve swift-state-graph and its macro
toolchain to link a port that does not use them.

`observation-memo`'s honesty test is written down and enforced by review: _would
a senior iOS engineer, given this workload, a deadline, and no reactive library,
write this?_ It therefore has no reader that records what it read, no dependency
graph, no automatic transitive invalidation, no propagated version stamps, and no
settlement algorithm. Build any of those and you have rebuilt Cog, and the
comparison stops meaning anything.

## The shared workload, and why it is dependency-free

All four runtimes run the **identical** eleven-phase interaction script, against
the identical fixtures, the identical scripted request boundary, and the
identical shadow model. Two runtimes exercising two similar-looking sessions
would let a result differ without either being wrong.

That is possible because `StorefrontWorkload`, in `Workload/`, depends on
**nothing at all — not even Cog**. It owns the domain model, the deterministic
fixtures, the heavy kernels, the pricing ladder, the scripted async service, the
sink, the checkpoint vocabulary, the `StorefrontRuntime` protocol, the shadow
model, and `StorefrontSessionDriver<Runtime>` — the generic driver that performs
the eleven phases. A port supplies a `StorefrontRuntime` conformance and gets the
script; it does not get to write its own.

The eleven phases are bootstrap, root data, initial row data, scroll, search,
filters, cart, detail, checkout, inventory burst, and teardown. A smoke run
records forty-one checkpoints. Twenty-eight of them are asserted identically and
unconditionally by every runtime — identity, checksum, money, promotion plan,
request quiescence — so declaring a convenient number buys a port nothing. Eleven
take their expected value from that runtime's own
`StorefrontRuntimeSemantics`, which is where a legitimate difference between
runtimes is _declared and then enforced_ rather than hidden; two more turn on a
declared capability and record an explicit skip when a runtime does not claim it,
so a missing proof is visible rather than silent.

[`Workload/README.md`](./Workload/README.md) documents the trace, the profiles,
and the determinism rules in detail.

## The agreement gate

**No Storefront number is reported until the cross-runtime agreement suite is
green.** A fast number that is also a wrong number is worse than no number, and
the whole claim of this benchmark is that Cog is faster at computing _the same
thing_, not faster at computing something else.

The suite lives in the test-only `cog-storefront-verification` package under
`Verification/Tests/StorefrontAgreementTests`, because nowhere else should see
all four runtimes. The runtime packages deliberately cannot see one another;
the runner consumes the same products for measurement but owns no correctness
tests.

It links all four runtimes, drives each through the identical trace on the
`smoke` profile, and requires that:

- every checkpoint holds for every runtime, and the only skipped checkpoints are
  the ones that runtime's declared semantics predict;
- the four agree exactly on the visible product identifiers, the rendered
  checksum, the settled suggestions, and the order total, and each agrees with
  the shadow it derived independently;
- every session ends with **zero** outstanding service requests — which is what
  separates "computed the same answer" from "computed the same answer for the
  same reasons";
- the `StorefrontRuntimeSemantics` fields that admit no variation really are
  invariant across the four, while the ones that legitimately differ are printed
  as a table rather than asserted, because that difference is the result the
  comparison exists to surface.

Run counts, cache sizes, and node counts are deliberately **not** compared. Those
are properties of the implementation strategy — they are what the benchmark
measures, and a suite that required them to match would fail four ways for three
correct reasons.

## Running it

```sh
mise run test:storefront-all          # every suite below, in one command

mise run test:storefront              # the dependency-free workload package
mise run test:storefront-cog          # the Cog runtime package
mise run test:storefront-runtimes     # the two plain-@Observable ports
mise run test:storefront-state-graph  # the swift-state-graph port
mise run test:storefront-agreement    # the cross-runtime gate — required before reporting
```

Each is a guarded Node wrapper, never a bare filtered `swift test`: SwiftPM exits
0 when a filter selects nothing, so the wrappers enumerate the built tests first
and refuse an authoritative executed count of zero.

The headless benchmark cuts and the SwiftUI driver:

```sh
mise run bench --filter 'perf-15-storefront-.*'          # the six Cog-only cuts
mise run bench:compact --filter 'perf-15-storefront-.*'  # the same, CompactArena
mise run bench --filter 'perf-16-storefront-.*'          # the sixteen comparison cuts
mise run bench --filter 'perf-1[56]-storefront-.*'       # both, in one session

mise run build:storefront             # build the SwiftUI benchmark app
mise run test:storefront-ui           # its release XCUIAutomation measurements
```

`perf-15` is the Cog-only cut family. `perf-16` is the four-runtime comparison
family, named `perf-16-storefront-<slug>-<cut>` over the cuts `cold`,
`session`, `async-burst`, and `interactions` — sixteen cuts, because there is no
cross-runtime footprint twin: that cut's preparation needs a neutral "start the
roots, materialize nothing" verb `StorefrontRuntime` does not have, so the
footprint stays Cog-only. Nothing in `perf-16` is thresholded. Running both
families in one session is worth doing: `perf-15` and `perf-16-cog` are the same
workload through two registrations, so a disagreement between them is a bug in
the lift.

The recorded numbers, their environment, and what the comparison does **not**
establish are in
[`docs/swift/impl/perf.md`](../../../docs/swift/impl/perf.md#cross-runtime-results).
Only the Cog port has a SwiftUI application today, so the UI measurements are
Cog-only; sibling applications for the comparison runtimes would land under
`Apps/`.

Read the absolute resident-memory column only from a run of the timing cuts
alone — the footprint cut retains its graphs, which raises the baseline:

```sh
mise run bench --filter 'perf-15-storefront-(cold|session|async-burst)'
```

## Further reading

- [`Workload/README.md`](./Workload/README.md) — the neutral workload, three
  profiles, determinism rules, and eleven-phase trace.
- [`Runtimes/CogRuntime/README.md`](./Runtimes/CogRuntime/README.md) — the Cog
  implementation and its package boundary.
- [`Runtimes/Observation/README.md`](./Runtimes/Observation/README.md) — the
  floor and hand-memoized competitor, their declared semantics, and every
  disclosed judgement call.
- [`Runtimes/StateGraph/README.md`](./Runtimes/StateGraph/README.md) and its
  [`API-NOTES.md`](./Runtimes/StateGraph/API-NOTES.md) — the swift-state-graph port and
  every measured library behavior it rests on, each with a `file:line` citation.
- [`Verification/README.md`](./Verification/README.md) — the test-only
  agreement and build-shape gates.
- [`Runner/README.md`](../Runner/README.md) — the harness, the six
  `perf-15` cuts, the metric rules, and the agreement gate in full.
- [`docs/swift/impl/perf.md`](../../../docs/swift/impl/perf.md) —
  the recorded numbers, their environments, and what the workload does **not**
  cover.
