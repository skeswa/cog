# Cog for Swift: profiling and optimization record

_August 20, 2026_

Where the time actually goes, and what changing it bought.

This is attribution work, and it is a different instrument from the benchmark
suite. A benchmark counts a cost at a boundary; the entries here open that
boundary and say which call sites the cost belongs to — with `sample`, with
`xctrace`, and with the purpose-built probe packages under
[`swift/Benchmarks/probes/`](https://github.com/skeswa/cog/tree/main/swift/Benchmarks/probes). That is why they
live apart from [benchmarks.md](./benchmarks.md), which records what the suite
measured, and from [design/perf.md](../design/perf.md), which owns the rules this
work exists to satisfy. Bare section references such as `perf §5` resolve in the
design document.

Read an entry as a pair: a profile that located a cost, and the change that
answered it. Where a change did not pay, that is recorded too — a route
investigated and rejected is worth as much to the next reader as one that
worked.

## M9: the post-M6 optimization pass

**Post-M6 call-site profile** — `M9-01`, 2026-08-18, `mactop` (Apple Silicon
arm64, 12 cores, 24 GB), macOS 26.4.1 / Darwin 25.4.0 (25E253), Xcode 26.4
(17E192) / Apple Swift 6.3 (swiftlang-6.3.0.123.5), release configuration with
debug info. This is the profile `M6-12a` said should precede any large
post-M6 investment, and the first recorded entry that attributes cost to **call
sites** rather than counting it at the boundary.

Measured outside the benchmark package, in a standalone one-executable harness,
because the question is where a turn's cost is incurred and the benchmark
harness cannot say. Allocations and ARC are attributed by a
`DYLD_INSERT_LIBRARIES` interposer over the malloc family and the Swift retain
and release entry points — including the bridge-object, unknown-object, and
Objective-C spellings, without which the pinned-key slope reads flat and the
measurement lies. Recording is armed for exactly one turn after two hundred
warm-up turns, so every count below is one turn's cost rather than an average.
Leaf time comes from `sample` at 1 ms over a six-second window. The harness and
its exact commands are recorded in
[`swift/Benchmarks/probes/M9-01-call-site-attribution.md`](https://github.com/skeswa/cog/blob/main/swift/Benchmarks/probes/M9-01-call-site-attribution.md).

The method reproduces every recorded count it overlaps: seven mallocs for a
simple-core steady turn (`M5-06`), five for the arena (`M6-11c`), and one retain
and one release per pinned key on simple against two on arena (`M5-07d`,
`M6-11c`). Allocation counts are taken with ARC recording disarmed, because
arming it costs one allocation of its own — a constant, and the reason the two
recording modes are separate.

**The seven steady-turn allocations, simple core, by call site.**

| Allocation | Call site                                              | What it is                                        |
| ---------- | ------------------------------------------------------ | ------------------------------------------------- |
| 1          | `CogOps.turn(_:to:name:)`, CogOps.swift:96             | escaping closure box for the write sugar          |
| 2          | `Cogs.turn(named:_:)`, Writer.swift:81                 | escaping closure box `withTurn` receives          |
| 3          | `Cogs.startTurn(named:)`, CogTurn.swift:283            | the `CogTurnID` object                            |
| 4          | `Cogs.startTurn(named:)`, CogTurn.swift:283            | the `CogTurn` object                              |
| 5          | `CogTurn.touch(_:)`, CogTurn.swift:59                  | `touchedSources` regrown from empty               |
| 6          | `Cogs.invalidateSubscribers(of:)`, CogSettle.swift:279 | the invalidation list regrown from empty          |
| 7          | `DerivedCogState.run(in:)`, DerivedCogState.swift:219  | the dependency list, reallocated by copy-on-write |

**None of the seven is graph representation.** Four are turn machinery that
exists whichever core is compiled, and three are per-turn arrays that cannot
reuse their capacity: two are regrown from empty, and the dependency list
reallocates because `run(in:)` holds the previous list in `previousDependencies`
while clearing `dependencies`, so `keepingCapacity: true` cannot keep anything. That is why the arena reached five rather
than zero: the representation swap could only ever move the minority of this
list it owns. A turn with no read costs the same seven; a tracked read of a
clean value costs none, so all seven belong to the write.

**Where a steady turn's time goes, simple core.** Leaf attribution over 5,073
samples; 1.97 µs per turn (2,000,000 turns in 3.94 s, three runs within 1%).

| Bucket                                   |    Share |
| ---------------------------------------- | -------: |
| ARC retain and release                   |    23.5% |
| Generic metadata instantiation           |    19.0% |
| Actor-isolation checks                   |    12.4% |
| Exclusivity checks (`swift_beginAccess`) |     8.2% |
| **Cog's own compiled code**              | **6.1%** |
| malloc and free                          |     5.5% |
| Value-witness copies                     |     5.3% |
| Weak-reference loads                     |     5.1% |
| Dynamic casts and conformance lookup     |     4.2% |
| Unattributed runtime and long tail       |    10.8% |

**About six percent of a steady turn is Cog's own code.** The rest is Swift
runtime machinery, and two of its largest buckets were not in view before this
profile:

- **Generic metadata and dynamic casts, ~23% together.** `Cogs.state(_:create:)`
  casts the stored existential back to a concrete `State` on every lookup
  (Cogs.swift:764), and `manualState(for:)` and `derivedState(for:)`
  instantiate `ManualCogState<Value>` and `DerivedCogState<Value>` metadata to
  do it. The settle walk then casts `state as? any DerivedCogSettleState`
  **twice per node per turn** — once entering and once exiting
  (CogSettle.swift:340 and :359) — and once more per boundary
  (CogObservationBoundary.swift:214). Part of that traffic reaches
  `_dyld_find_protocol_conformance_on_disk`, the uncached lookup path.
- **Actor-isolation checks, ~12%.** `CogState.addSubscriber(_:)` pays
  `swift_task_isCurrentExecutor` and main-executor resolution on every
  dependency re-record (CogSettle.swift:79–80), as does
  `CogObservationBoundary.notifyValueChange()`. The per-turn `CogTurn` and
  `CogTurnID` pair pays them again in `isolated deinit`, so allocation 3 and
  allocation 4 cost more than their mallocs.

**Pinned-key slope, both cores.** One keyed source written and read; every
other key pinned and untouched.

| Pinned keys | simple retains / releases | arena retains / releases |
| ----------: | ------------------------: | -----------------------: |
|           1 |                  78 / 104 |                  56 / 78 |
|         100 |                 177 / 203 |                254 / 276 |
|         500 |                 577 / 603 |            1,054 / 1,076 |
|       1,000 |             1,077 / 1,103 |            2,054 / 2,076 |

Exactly one retain and one release per pinned key on simple, exactly two on
arena — the `M6-12a` result, reproduced independently. At a thousand pinned
keys **79.9% of the turn's leaf samples are ARC**, and the site is one line:
`flushClassObservationBoundaries` iterates `observationStates`, an array of
`any CogObservationState`, retaining and releasing every element whether or not
it changed (CogObservationBoundary.swift:212).

**Per-node settle cost, depth-100 keyed chain.** One source write pulled
through a hundred automatic nodes.

| Core   | mallocs / turn | retains / turn | releases / turn | wall clock / turn |
| ------ | -------------: | -------------: | --------------: | ----------------: |
| simple |            107 |          4,176 |           4,902 |            118 µs |
| arena  |              5 |          1,254 |           1,376 |            101 µs |

Simple pays about **one allocation, forty-one retains, and forty-nine releases
per node per turn**. Leaf time on that shape is 33.9% ARC, 16.2% generic
metadata, 7.7% isolation checks, 7.1% dynamic casts, 5.8% weak loads, and 5.4%
exclusivity, against 5.0% for Cog's own code.

This chain is a keyed `CogBox` recursion, **not** the Kairo deep benchmark that
`M6-11c` measured a 33% instruction regression on. It is a different shape and
the two must not be compared; it is recorded because it isolates per-node cost,
which the Kairo shape does not.

**What the profile settles.** The ranking below is measurement, not the
code-reading that opened issue #373, and it reorders that issue's routes:

1. The boundary flush is the largest single defect and the one with a name
   already: it is four-fifths of a turn once a screen has scrolled, and it is
   `M6-12a`'s stated trigger for reconsidering the core.
2. Shared turn machinery, not representation, owns the steady turn. Four
   allocations, two `isolated deinit` executor-check pairs, and three arrays
   rebuilt from empty are all common-path cost that no core swap can reach.
3. Existential casts, generic metadata, and dynamic isolation checks are a
   third of a steady turn and were entirely absent from the code-reading
   diagnosis. They are shared machinery too.

Any rerun of the simple-versus-arena comparison before those three are fixed
would measure the same coat on both candidates, which is what `M6-12a` already
did. `M9-17` reruns it afterwards.

**What a steady turn is made of now** — `M9-12`, 2026-08-19, same host and
toolchain, 5,100 leaf samples over a 1.53 µs turn. The `M9-01` profile is the
before; this is the after, and it is what the remaining routes are chosen from.

| Bucket                               | `M9-01` |      now |
| ------------------------------------ | ------: | -------: |
| ARC retain and release               |   23.5% |    28.5% |
| Generic metadata instantiation       |   19.0% |    18.6% |
| Exclusivity checks                   |    8.2% |    12.5% |
| **Cog's own compiled code**          |    6.1% | **9.1%** |
| Actor-isolation checks               |   12.4% |     8.9% |
| Weak-reference loads                 |    5.1% |     5.8% |
| Dynamic casts and conformance lookup |    4.2% |     1.1% |
| malloc and free                      |    5.5% | **0.0%** |

Allocation is gone, casts are nearly gone, and isolation checks are down by a
third. The shares that grew did so because the turn shrank around them.

**Generic metadata is now the largest addressable cost**, and it is
concentrated: `manualState(for:)` and `derivedState(for:)` account for most of
it, because resolving a descriptor and key goes through a function generic over
the concrete state class, so every read asks the runtime for
`ManualCogState<Value>` or `DerivedCogState<Value>` metadata.

`M9-12` measured the cheap version of this and rejected it. Replacing the
lookup's checked cast with `unsafeDowncast` is worth 5% of a steady turn — and
the cast guards an internal invariant, so a violation is a Cog bug rather than
bad input, and an unchecked cast converts a clear release-build error into
undefined behavior. perf §1 rule 2 is not tradeable against perf §1 rule 3 at that price.
Marking the two lookups `@inline(__always)` alongside it measured within noise.

The version that keeps the check is a per-context cache on the declaration's
descriptor, which removes the dictionary hash and the metadata request together
because the descriptor is already the concrete generic type. That is issue
#373's route D, and it needs its own lifetime-release coverage before it is
worth landing.

**Where the arena's ordinary turn goes** — `M9-21`, 2026-08-19, same host and
toolchain, 5,118 leaf samples. Recorded because the `M9-17` comparison shows
the arena losing the smallest turn by a third, and the reason turns out to have
nothing to do with its representation.

| Bucket                         | simple |     arena |
| ------------------------------ | -----: | --------: |
| ARC retain and release         |  28.5% |  **6.5%** |
| Exclusivity checks             |  12.5% | **31.7%** |
| Generic metadata instantiation |  18.6% | **26.0%** |
| Cog's own compiled code        |   9.1% |     12.2% |
| Value-witness copies           |   5.3% |      8.2% |
| Actor-isolation checks         |   8.9% |      2.2% |

**The arena won the argument it was built for and lost two nobody had.** Its
ARC traffic is a fifth of the simple core's, which is perf §5's rule working exactly
as designed. It then spends that gain, and more, on exclusivity checks and
metadata requests that the class-state core mostly does not make.

Attribution, by the Cog frame beneath each cost:

| Cost        | Site                                     | Samples |
| ----------- | ---------------------------------------- | ------: |
| metadata    | `CogArenaCore.manualRecord(for:)`        |     531 |
| metadata    | `CogArenaValueColumn.installedRow(for:)` |     527 |
| exclusivity | `CogArenaStorage.index(of:)`             |     382 |
| metadata    | `CogArenaValueColumn.publish(at:)`       |     384 |
| metadata    | `CogArenaValueColumn.stage(_:at:)`       |     359 |
| metadata    | `CogArenaCore.manualLocation(for:)`      |     292 |
| exclusivity | `CogArenaCore.settle(_:in:)`             |     175 |

Two shapes, and both are already named in perf §5 and issue #373 as reserved
work nobody had priced:

**Exclusivity, ~32%.** The arena's columns are mutable stored properties on
classes, so every `arena.flags[row]` and every column touch pays a dynamic
exclusivity check with its thread-local bookkeeping. perf §5 reserved the fix —
borrow each column once per turn phase rather than per access — and route E
separately noticed that `index(of:)` re-validates a generation on nearly every
column touch, which `CogArenaStorage.swift` itself anticipates hoisting. They
are the same 382 samples seen from two directions.

**Metadata, ~26%.** Resolving one value walks record → location → column → row,
and every layer is generic over the value type, so each asks the runtime for
`CogArenaValueColumn<Value>` metadata it has already been given. This is the
simple core's `M9-12` problem with more layers, and the same remedy applies:
cache the resolved location on the declaration's descriptor per context.

Together those two are about 1,240 ns of a 2,150 ns turn, against a 510 ns gap
to the simple core. Neither would close it entirely; both are aimed well past
it, and the metadata fix would narrow rather than close because it helps the
simple core too.

**The arena's exclusivity cost, removed** — `M9-22`, 2026-08-19, same host and
toolchain. `M9-21` measured dynamic exclusivity enforcement at 31.7% of the
arena's ordinary turn, the largest single cost in that core.

| Measure               |   before |        after |
| --------------------- | -------: | -----------: |
| steady turn p50       | 2,152 ns | **1,696 ns** |
| allocations           |        0 |            0 |
| retains / releases    |  45 / 53 |      46 / 54 |
| 1 pinned key p50      | 2,861 ns | **2,390 ns** |
| 1,000 pinned keys p50 | 2,902 ns | **2,441 ns** |

**21% off the smallest turn, and the everyday gap to the shipping core all but
closes**: 1,696 ns against 1,639 ns, where `M9-17` measured 2,152 against 1,639.
The pinned-key slope stays flat.

The change is `@exclusivity(unchecked)` on the arena's scalar columns — the
storage columns, the core's frame and record buffers, and the propagation
stack. Each is a mutable stored property on a class, so every touch was
bracketed by `swift_beginAccess`/`swift_endAccess` with thread-local
bookkeeping, and one turn touches them dozens of times.

Safe by construction rather than by convention, on three counts recorded in
`CogArenaStorage`: the classes are `@MainActor`, so no second thread can hold an
access; every element type is trivial, so no destructor — library or user — can
run inside an access and re-enter; and no method holds an access open across a
call. The third is an invariant a later edit could break, so it is written into
the source as an instruction rather than left to be rediscovered.

**The typed value columns keep full enforcement.** Their element type is the
user's, and releasing one can run arbitrary `deinit` code inside an access.
Annotating them measured a further 4.4%, and it was declined: an exclusivity
trap with a clear message is worth more than 100 ns in a research core.

Two things this settles about perf §5's reserved work. The per-phase
`withUnsafeMutableBufferPointer` borrow **does not apply here**: every hot loop
calls back into the arena inside its body — `settle` reaches a user selector,
the propagation loop reads `flags` through the edge storage — and `Array`'s
borrow leaves an empty array in place for the duration, so re-entry would read
zero rows rather than trap. That is strictly more dangerous than the attribute
for the same win. And the whole-library `-enforce-exclusivity=unchecked` flag,
also reserved there, measures 1,601 ns against this change's 1,696 — most of
the win for a fraction of the blast radius, which is why the targeted attribute
is what landed.

**The arena's metadata cost, and where the everyday gap went** — `M9-23`,
2026-08-19, same host and toolchain. `M9-21` measured generic-metadata
instantiation at 26% of the arena's ordinary turn; `M9-22` removed the
exclusivity third; this removes most of the metadata third.

| Measure             |  `M9-17` |  `M9-22` |          now | simple core |
| ------------------- | -------: | -------: | -----------: | ----------: |
| steady turn p50     | 2,198 ns | 1,696 ns | **1,337 ns** |    1,639 ns |
| steady retains      |       47 |       46 |       **38** |          62 |
| 16-consumer fan p50 |    21 µs |        — |    **13 µs** |       37 µs |
| 100-node chain p50  |   109 µs |        — |    **94 µs** |      128 µs |
| allocations         |        0 |        0 |            0 |           0 |

**The arena is now the faster core on every shape except keyed reads.** `M6-11c`
had it losing the smallest turn by 10% and `M9-17` by 34%; it now wins it by
18%, having never changed its representation.

The change memoizes a keyless declaration's resolved column and slot on its
descriptor, per context. That skips a `recordsByIdentity` lookup, a
`CogStateIdentity` construction, a `slots` lookup, and — the expensive part — the
`record.column as? CogArenaValueColumn<Value>` downcast that instantiated the
metadata. Resolution sites in the profile go from 405 samples to 8.

Two design points worth keeping:

**Context identity is a monotonic counter, not an `ObjectIdentifier`.** A
deallocated `Cogs` address is reusable, so a memo matched against a recycled
address could serve another context's state — an ABA hazard with a
cross-context correctness failure at the end of it. A never-reused counter
cannot be impersonated.

**The memo validates itself rather than trusting its invalidation hooks.**
Releasing a row advances its generation before the index can be reused, so a
stale memo fails `arena.contains(slot)` on its own. The explicit eviction on
release and on context teardown is hygiene; correctness does not depend on
having found every path. Descriptors outlive contexts — they are `static let` —
so this is the property that matters.

**Keyed references keep the old path**, deliberately: `box[key]` would need a
per-key memo and a wider invalidation surface for a shape this measurement does
not cover. It shows in the numbers — the arena's pinned-key turn is unchanged at
about 2.6 µs against the simple core's 2.2 µs, and that is now the only everyday
shape where the arena loses.

**The remaining metadata is not reachable this way.** 782 of the 1,007 residual
samples are inside `CogArenaValueColumn` itself — `installedRow`, `stage`,
`publish`, `current` — where the cost is `ContiguousArray<Value?>` access in
unspecialized generic code. No per-call-site cache helps that; it needs
specialization, which is a different route.

**Where the arena's build cost goes** — `M9-26`, 2026-08-19, same host and
toolchain. `M9-25` established the 2.2× and did not explain it, so the `M9-01`
probe gained a `build` workload: PERF-03's exact shape, a fresh context per
iteration, so everything the other workloads deliberately push behind their
warm-up is the measured region instead. One build of a thousand states:

| Counter     | simple | arena      |
| ----------- | ------ | ---------- |
| allocations | 4,525  | 5,697      |
| retains     | 22,504 | **17,527** |
| releases    | 38,052 | **24,745** |

**Neither counter explains it.** Allocations are 26% higher, which cannot
produce 2.2×, and ARC is 22% _lower_ — the arena genuinely touches fewer
reference counts building a graph, exactly as its design intends. The cost is
in leaf CPU time that no counting metric sees, so it needs `sample`. Six
seconds each, bucketed by leaf symbol as the recorded tables are:

| Bucket                            | simple | arena     | absolute change |
| --------------------------------- | ------ | --------- | --------------- |
| generic metadata + witness tables | 17.7%  | **28.6%** | **~3.5×**       |
| unspecialized generic value work  | 25.7%  | 30.5%     | ~2.6×           |
| array growth and copying          | 1.5%   | 6.8%      | ~10×            |
| dictionary and `AnyHashable` keys | 12.2%  | 9.3%      | ~1.7×           |
| ARC                               | 13.0%  | 3.3%      | ~0.55×          |
| dynamic casts, conformance lookup | 10.9%  | 3.1%      | ~0.63×          |
| Cog's own code                    | 8.4%   | 10.0%     | ~2.6×           |

Percentages are of each core's own run; the absolute column multiplies them by
`M9-25`'s 2,320 µs against 1,068 µs, which is the comparison that matters. The
two runs sampled almost identical leaf totals (4,808 and 4,817), so the shares
are directly comparable as fractions of time.

**The cost is the erased-storage crossing, not the layout.** A simple-core
state is one object whose fields are concrete and inline. An arena state is
split across the scalar columns and a per-descriptor generic
`CogArenaValueColumn<Value>`, reached through the `AnyObject` in
`CogArenaDescriptorRecord` and recovered as its concrete type at each touch.
That crossing is what instantiates metadata and looks up witness tables, and
construction pays it per state.

Construction pays it and a steady turn largely does not, because `M9-23`'s memo
files the resolved slot-and-column pair on the declaration — **and only for a
keyless one**, since one declaration names a whole keyed family and a
single-entry memo would thrash between its members. PERF-03 is a hundred
percent keyed. So the build workload is precisely the path the memo does not
cover, which is the same reason the arena still loses keyed lookups. The two
findings are one finding.

This also names what a fix would have to be. Nothing here is wasted work that a
cache can skip a second time; it is unspecialized generic code, so the route is
specialization, which is the same conclusion `M9-24` reached from the steady
turn. Route F's remaining question is whether that is reachable without
widening the public API.

**The typed frontier recovers specialization, now the default size trade** —
2026-08-21, environment E5 in [benchmarks.md](./benchmarks.md). The staged
experiment implemented the stable route recorded by `M9-26`: make only the
value-typed frontier `@inlinable` and promote exactly the
internal declarations those bodies name to `@usableFromInline`. Record-closure
formation stays on that frontier, so client compilation sees the concrete
`Value` through recomputation rather than specializing only array access.

Across seven paired PERF-03 runs, the median baseline p50 was 2,163 µs and the
frontier median was 1,102 µs, a 49.1% reduction. Median instructions fell from
55 million to 27 million. The standalone build probe's allocations fell from
5,697 to 1,699. A temporary exported-specialization control arm measured about
1.20 ms and 26–27 million instructions: the stable mechanism reached the same
ceiling without an underscored compiler attribute.

The binary records the cost of making this the default. The specialized arena's
arm64 Storefront `__TEXT` measured 991,232 bytes against 827,392 for the compact
historical simple build, about 20% larger. Rescue experiments that pulled record
creation and progressively colder operations back behind opaque calls reduced
the win before they reduced size enough; none met both the plan's 20% speed gate
and 5% app-size gate. Later stakeholder research found about 80% of users would
accept that size cost for the speed and overhead improvements, changing the
product weighting rather than the measurement.

The specialized arena with pool edges is therefore the sole core and the
default. The simple selector is retired. The additive `CompactArena` package
trait is the explicit opt-out: it suppresses this frontier while leaving the
arena representation, generic compiled fallbacks, debug behavior, and Cog's
public API unchanged. The trait keeps the unspecialized arena measurable. Since
SwiftPM unions traits across the graph, the final application owns the compact
choice rather than a reusable dependency choosing it on the application's
behalf.
