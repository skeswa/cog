# Probe: call-site attribution for turns, settles, and pinned keys

`M9-01`, run 2026-08-18. The profile `M6-12a` said should precede any large
post-M6 investment, kept because the routes in issue #373 were opened from
code reading and a ranking that no measurement stands behind is a guess with a
tablecloth on.

The results this probe produced, and the conclusions drawn from them, are in
[optimization.md](../../../docs/swift/impl/optimization.md) under **Post-M6 call-site
profile**. This document is the method.

## Environment

|               |                                                                                       |
| ------------- | ------------------------------------------------------------------------------------- |
| Host          | `mactop` — Apple Silicon arm64, 12 cores, 24 GB, macOS 26.4.1, Darwin 25.4.0 (25E253) |
| Xcode         | 26.4 (17E192)                                                                         |
| Swift         | 6.3 (`swiftlang-6.3.0.123.5`), target `arm64-apple-macosx26.0`                        |
| Configuration | release, with `-g` so `atos` can resolve a frame to a source line                     |

**This is not the runner, and these are not baselines.** §9.6's simple-core
figures were recorded on this host under this toolchain, so the numbers here are
directly comparable to them; the CI runner is the `cog-mini` on Xcode 26.6, and
baselines belong to it.

## Why not the benchmark package

The benchmark harness counts allocations and ARC at the boundary of a measured
region. That is the right shape for a gate and the wrong shape for this
question: it can say a steady turn allocates seven times, and it cannot say
which seven lines allocate. Every route in issue #373 is a proposal to delete a
specific call site, so the probe has to attribute cost to call sites.

It is also deliberately _not_ wired into the gate. Interposition perturbs what
it measures — see the artifact below — and a gate that depends on
`DYLD_INSERT_LIBRARIES` is a gate that stops working when a future toolchain
changes symbol visibility.

## The harness

A standalone SwiftPM executable that depends on the root package by path, so it
compiles against the same library a consumer would, including the core and
value-reference selectors. Sources live beside this document in
[`M9-01/`](./M9-01/):

- `Package.swift` — the executable package, path-dependent on the repository
  root, carrying the library's own Swift settings so `@MainActor` default
  isolation matches.
- `Sources/CogProfile/main.swift` — the workloads: `steady` (one write and one
  tracked read), `turn` (a write with no read), `read` (a tracked read of a
  clean value), `pinned` (one live key beside `K` pinned ones), `deep` (a
  source pulled through a chain of `K` automatic nodes), and `build` (`K` keyed
  source-and-consumer pairs constructed in a fresh context).
- `interpose.c` — the profiler.

`main.swift` runs two hundred warm-up iterations, arms the profiler, runs
exactly the requested number of measured iterations, and disarms it. One armed
iteration therefore reports **one turn's cost**, not an average, which is what
makes a count of seven attributable to seven lines.

## The profiler

`interpose.c` builds into a dylib loaded with `DYLD_INSERT_LIBRARIES`. It
interposes the malloc family and the Swift runtime's reference-counting entry
points, captures a backtrace on every call made while armed, aggregates
identical stacks by identity, and prints each stack with its count.

**Interpose every retain spelling or the measurement lies.** A first version
hooked `swift_retain` and `swift_release` alone and reported the pinned-key
slope as _flat_ — 23 retains per turn at one pinned key and at a thousand —
which would have refuted `M5-07d` and `M6-12a` outright. The per-pinned-key
traffic is `swift_bridgeObjectRetain` and `swift_unknownObjectRetain`, because
the boundary array holds existentials over `AnyHashable`-keyed states. With
those, the objective-C spellings, and the `_n` variants added, the probe
reproduces the recorded slope exactly. A profiler that silently misses a family
of calls does not report a smaller number; it reports a different shape.

Recording is guarded by a thread-local reentrancy flag, since `backtrace` and
the report path allocate.

## Historical invocation

This probe is a measurement record, not a command for the current tree. The
commands below describe revision `M9-01`, when a bare build selected the simple
core and `COG_TEST_CORE=arena` selected its comparison. The current manifest
rejects that retired selector deliberately. Use `mise run bench` for the
specialized arena or `mise run bench:compact` for the supported public compact
comparison; neither can recreate the removed simple core.

```sh
cd swift/Benchmarks/probes/M9-01

# The profiler.
clang -dynamiclib -O1 -g -o libcogprof.dylib interpose.c \
  -L/usr/lib/swift -lswiftCore -lobjc

# On the M9-01 revision: the then-shipping simple core and arena comparison.
swift build -c release -Xswiftc -g
COG_TEST_CORE=arena swift build -c release -Xswiftc -g --scratch-path .build-arena
```

Every `.build-*` scratch path is git-ignored, so comparison builds can sit side
by side without reaching the working copy.

`CogProfile <workload> <mode> <armed-iterations> [parameter]`, where mode is a
bit set: 1 records allocations, 2 records retains and releases, 3 records both.

```sh
# The seven steady-turn allocations, one turn, with their call sites.
DYLD_INSERT_LIBRARIES=./libcogprof.dylib ./.build/release/CogProfile steady 1 1

# ARC traffic against pinned-key count — the slope, not a single number.
for k in 1 100 500 1000; do
  DYLD_INSERT_LIBRARIES=./libcogprof.dylib \
    ./.build/release/CogProfile pinned 2 1 "$k"
done

# Per-node settle cost on a hundred-node chain, both cores.
DYLD_INSERT_LIBRARIES=./libcogprof.dylib ./.build/release/CogProfile deep 3 1 100
DYLD_INSERT_LIBRARIES=./libcogprof.dylib ./.build-arena/release/CogProfile deep 3 1 100

# One build of PERF-03's thousand states, both cores (`M9-26`).
DYLD_INSERT_LIBRARIES=./libcogprof.dylib ./.build/release/CogProfile build 1 1 500
DYLD_INSERT_LIBRARIES=./libcogprof.dylib ./.build-arena/release/CogProfile build 1 1 500
```

**`build` is the one workload whose warm-up is short on purpose.** Every other
workload measures a steady turn and needs two hundred iterations to get first-run
costs behind the measured region. `build` measures those costs — one iteration is
a thousand states rather than one turn — so it warms twice, enough to bind dyld
stubs and settle the global metadata cache without hiding the per-state work
under them.

**Take allocation counts with ARC recording disarmed.** Arming it costs exactly
one extra allocation per armed region — measured as a constant across steady,
pinned, and deep workloads — so `mode 1` reports seven for a steady turn where
`mode 3` reports eight. Mode 1 is the number that matches `M5-06`.

## Symbolicating a stack

The report prints the main executable's load address, which is what `atos`
needs to turn a frame into a source line:

```sh
COGPROF image /…/CogProfile 0x1046ec000
atos -o ./.build/release/CogProfile -l 0x1046ec000 0x104702b10
```

Release builds inline aggressively, so a leaf frame often names the caller that
absorbed it. Frames that resolve to `<compiler-generated>` are inlined bodies;
read the next frame out, and confirm against the source before recording a
line number.

## Leaf time

Wall-clock attribution comes from `sample`, over a long unarmed run, so the
profiler perturbs nothing:

```sh
./.build/release/CogProfile steady 0 20000000 & sample $! 6 1 -f steady.txt
```

The "Sort by top of stack" section of that report is what §9.6's percentage
table buckets. Bucketing is by leaf symbol — ARC, generic metadata, isolation
checks, exclusivity, malloc, weak loads, value witnesses, and everything
compiled into `CogProfile` itself, which is the row that matters: it is Cog's
own code, and on a steady turn it is about six percent.
