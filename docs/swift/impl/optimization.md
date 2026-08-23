# Cog for Swift: optimization record

_August 20, 2026_

This file shows where runtime time went and what each change saved. It uses
call-site profiles from `sample`, `xctrace`, and the probes under
`swift/Benchmarks/probes/`.

[benchmarks.md](./benchmarks.md) records end-to-end numbers.
[design/perf.md](../design/perf.md) owns the runtime rules. This file records
cause and effect inside those numbers.

## M9 profiles and changes

Unless noted, these measurements used `mactop`: Apple Silicon arm64, 12 cores,
24 GB, macOS 26.4.1, Xcode 26.4 (17E192), and Swift 6.3. Release builds kept
debug symbols.

### M9-01: first call-site profile

The standalone probe warmed 200 turns, then counted exactly one turn. A malloc
interposer counted allocations. Swift retain/release hooks counted ARC,
including bridge, unknown-object, and Objective-C forms. ARC and allocation
counts ran separately because enabling ARC recording allocates once.

The probe matched older results: seven allocations for a simple-core steady
turn, five for arena, one retain/release pair per pinned key on simple, and two
pairs on arena. See
[`M9-01-call-site-attribution.md`](https://github.com/skeswa/cog/blob/main/swift/Benchmarks/probes/M9-01-call-site-attribution.md)
for commands.

#### Seven simple-core allocations

| Count | Call site                         | Allocation                         |
| ----: | --------------------------------- | ---------------------------------- |
|     1 | `CogOps.turn(_:to:name:)`         | Closure box for scalar-write sugar |
|     1 | `Cogs.turn(named:_:)`             | Closure box passed to `withTurn`   |
|     1 | `Cogs.startTurn(named:)`          | `CogTurnID`                        |
|     1 | `Cogs.startTurn(named:)`          | `CogTurn`                          |
|     1 | `CogTurn.touch(_:)`               | Regrown touched-source array       |
|     1 | `Cogs.invalidateSubscribers(of:)` | Regrown invalidation array         |
|     1 | `DerivedCogState.run(in:)`        | Copy-on-write dependency array     |

Four allocations belong to shared turn machinery. Three belong to arrays that
could not keep capacity. The dependency array was still shared with the saved
old list when code cleared it. This explains why changing graph storage alone
could not reach zero allocations.

#### Steady-turn time

The simple core ran 2,000,000 turns in 3.94 seconds, or 1.97 µs per turn. A
six-second, 1 ms profile produced 5,073 samples:

| Cost                         | Share |
| ---------------------------- | ----: |
| ARC retain and release       | 23.5% |
| Generic metadata             | 19.0% |
| Actor checks                 | 12.4% |
| Exclusivity checks           |  8.2% |
| Cog code                     |  6.1% |
| malloc and free              |  5.5% |
| Value copies                 |  5.3% |
| Weak loads                   |  5.1% |
| Casts and conformance lookup |  4.2% |
| Other runtime work           | 10.8% |

Most generic and cast cost came from looking up typed states through erased
storage. The settle walk also cast each automatic node twice and each boundary
once. Actor checks came from subscriber updates, boundary notices, and isolated
turn-object deinits.

#### Pinned-key slope

The probe wrote one keyed source while other keys stayed pinned:

| Pinned keys | Simple retains/releases | Arena retains/releases |
| ----------: | ----------------------: | ---------------------: |
|           1 |                78 / 104 |                56 / 78 |
|         100 |               177 / 203 |              254 / 276 |
|         500 |               577 / 603 |          1,054 / 1,076 |
|       1,000 |           1,077 / 1,103 |          2,054 / 2,076 |

At 1,000 keys, ARC took 79.9% of samples. The cause was one loop over all
`observationStates`, which retained every boundary even when only one changed.

#### Cost per settled node

A write pulled through a depth-100 keyed chain:

| Core   | Allocs | Retains | Releases |   Time |
| ------ | -----: | ------: | -------: | -----: |
| Simple |    107 |   4,176 |    4,902 | 118 µs |
| Arena  |      5 |   1,254 |    1,376 | 101 µs |

The simple core paid about one allocation, 41 retains, and 49 releases per
node. This keyed recursion is not the Kairo deep benchmark, so its numbers must
not be compared with that shape.

The profile set three priorities:

1. Notify only changed boundaries.
2. Remove shared turn allocations and isolated-deinit checks.
3. Reduce erased casts, metadata, and actor checks.

### M9-12: shared turn cost after fixes

After those changes, a turn took 1.53 µs. A 5,100-sample profile showed:

| Cost                         | Before | After |
| ---------------------------- | -----: | ----: |
| ARC                          |  23.5% | 28.5% |
| Generic metadata             |  19.0% | 18.6% |
| Exclusivity                  |   8.2% | 12.5% |
| Cog code                     |   6.1% |  9.1% |
| Actor checks                 |  12.4% |  8.9% |
| Weak loads                   |   5.1% |  5.8% |
| Casts and conformance lookup |   4.2% |  1.1% |
| malloc and free              |   5.5% |  0.0% |

Larger shares do not mean those costs grew; the turn became shorter around
them. Allocation disappeared, casts nearly disappeared, and actor checks fell
by about one third.

Generic state lookup became the largest clear target. An `unsafeDowncast`
saved 5%, but it would turn an internal invariant failure into undefined
behavior. The change was rejected. Forced inlining was noise. A checked,
per-context descriptor cache was the safe route.

### M9-21: arena turn profile

The arena already used much less ARC than simple, but spent more on exclusivity
and generic metadata:

| Cost             | Simple | Arena |
| ---------------- | -----: | ----: |
| ARC              |  28.5% |  6.5% |
| Exclusivity      |  12.5% | 31.7% |
| Generic metadata |  18.6% | 26.0% |
| Cog code         |   9.1% | 12.2% |
| Value copies     |   5.3% |  8.2% |
| Actor checks     |   8.9% |  2.2% |

The hottest sites were:

| Cost        | Site                                     | Samples |
| ----------- | ---------------------------------------- | ------: |
| Metadata    | `CogArenaCore.manualRecord(for:)`        |     531 |
| Metadata    | `CogArenaValueColumn.installedRow(for:)` |     527 |
| Exclusivity | `CogArenaStorage.index(of:)`             |     382 |
| Metadata    | `CogArenaValueColumn.publish(at:)`       |     384 |
| Metadata    | `CogArenaValueColumn.stage(_:at:)`       |     359 |
| Metadata    | `CogArenaCore.manualLocation(for:)`      |     292 |
| Exclusivity | `CogArenaCore.settle(_:in:)`             |     175 |

Scalar array access paid a dynamic exclusivity check on nearly every touch.
Typed lookup repeatedly crossed record → location → column → row and requested
metadata for `CogArenaValueColumn<Value>`.

### M9-22: remove safe scalar exclusivity checks

| Measure               |   Before |    After |
| --------------------- | -------: | -------: |
| Steady turn p50       | 2,152 ns | 1,696 ns |
| Allocations           |        0 |        0 |
| Retains/releases      |  45 / 53 |  46 / 54 |
| 1 pinned key p50      | 2,861 ns | 2,390 ns |
| 1,000 pinned keys p50 | 2,902 ns | 2,441 ns |

`@exclusivity(unchecked)` on scalar columns removed 21% from the smallest turn.
It is safe for these fields because:

- their classes are MainActor-only;
- their element types are trivial, so no deinit can re-enter; and
- no method keeps an access open across a call.

Typed value columns keep full checks because releasing a user value can run
arbitrary deinit code. Removing those checks saved another 4.4%, but the clear
trap was worth more than about 100 ns.

Borrowing each array through `withUnsafeMutableBufferPointer` was less safe.
Hot loops call back into the arena, while the borrow leaves the array empty.
Library-wide `-enforce-exclusivity=unchecked` reached 1,601 ns, but changed far
more code. The targeted field setting kept most of the gain.

### M9-23: cache keyless arena locations

| Measure             |    M9-17 |    M9-22 | After cache |   Simple |
| ------------------- | -------: | -------: | ----------: | -------: |
| Steady turn p50     | 2,198 ns | 1,696 ns |    1,337 ns | 1,639 ns |
| Steady retains      |       47 |       46 |          38 |       62 |
| 16-consumer fan p50 |    21 µs |        — |       13 µs |    37 µs |
| 100-node chain p50  |   109 µs |        — |       94 µs |   128 µs |
| Allocations         |        0 |        0 |           0 |        0 |

The arena became faster than simple except on keyed reads. A descriptor now
caches its resolved column and slot for each context. This removes identity and
slot dictionary lookups plus the typed column cast. Profile samples at those
sites fell from 405 to 8.

Two checks protect the cache:

- Context identity is a never-reused counter. A memory address could be reused
  by a later context and cause an ABA bug.
- A cached slot checks its generation. Release advances the generation before
  reuse, so correctness does not depend on every cleanup hook running.

Keyed references keep the old path because one descriptor names many keys.
Their arena turn stayed near 2.6 µs versus 2.2 µs for simple. Most remaining
metadata cost sat inside unspecialized generic value-column methods, so the
next route had to be specialization.

### M9-26: graph-build profile

PERF-03 builds 1,000 fresh keyed states. Before specialization, arena took
2,320 µs and simple took 1,068 µs.

| Counter     | Simple |  Arena |
| ----------- | -----: | -----: |
| Allocations |  4,525 |  5,697 |
| Retains     | 22,504 | 17,527 |
| Releases    | 38,052 | 24,745 |

The 26% allocation increase did not explain a 2.2× slowdown, and arena ARC was
lower. Six-second profiles gave the cause:

| Cost                             | Simple | Arena | Absolute change |
| -------------------------------- | -----: | ----: | --------------: |
| Generic metadata and witnesses   |  17.7% | 28.6% |      about 3.5× |
| Unspecialized generic value work |  25.7% | 30.5% |      about 2.6× |
| Array growth and copies          |   1.5% |  6.8% |       about 10× |
| Dictionaries and keys            |  12.2% |  9.3% |      about 1.7× |
| ARC                              |  13.0% |  3.3% |     about 0.55× |
| Casts and conformance lookup     |  10.9% |  3.1% |     about 0.63× |
| Cog code                         |   8.4% | 10.0% |      about 2.6× |

Each profile had about 4,800 leaf samples. The arena split one state across
scalar columns and `CogArenaValueColumn<Value>`, reached through erased storage.
Fresh keyed construction crossed that erased boundary for every state. The
keyless cache could not help because one keyed descriptor names many rows.

### Typed frontier and shipping choice

The final change made only the value-typed frontier `@inlinable` and exposed
the needed internal symbols as `@usableFromInline`. User compilation could then
specialize the concrete `Value` through record creation and recomputation.

Seven paired PERF-03 runs on environment E5 measured:

| Measure             |   Baseline | Typed frontier |     Change |
| ------------------- | ---------: | -------------: | ---------: |
| Median p50          |   2,163 µs |       1,102 µs |     -49.1% |
| Median instructions | 55 million |     27 million | about -51% |
| Probe allocations   |      5,697 |          1,699 |     -70.2% |

A temporary compiler-attribute control reached about 1.20 ms and 26–27 million
instructions. The stable frontier reached the same range without an underscored
attribute.

Specialization increased arm64 Storefront `__TEXT` from 827,392 bytes for the
old compact simple build to 991,232 bytes, about 20%. Moving cold operations
back behind opaque calls lost speed before it saved enough size. No tested
variant met both the old 20% speed and 5% app-size goals. Later research found
about 80% of users would accept the size cost for the speed and lower overhead.

The specialized arena with pool edges is now the only shipping core and the
default. `CompactArena` turns off the typed frontier while keeping arena
storage, pool edges, debug behavior, generic fallbacks, and public API. SwiftPM
combines traits across the graph, so the final app—not a library dependency—must
choose compact mode.
