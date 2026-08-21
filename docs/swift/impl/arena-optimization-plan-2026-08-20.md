# Cog for Swift: arena specialization research and design

_August 20, 2026_

This is a frozen research report and a staged plan. It answers the question
`M9-26` left open, which issue #373 calls route F: can we make the arena core
fast at building keyed graphs using only stable Swift features? A temporary
experiment already proved a big speedup is possible — about 49% of PERF-03's
build time — but it used an unstable compiler attribute and a hard-coded list
of types. This report shows how to get the same win without either.

The recorded numbers this report builds on are in
[benchmarks.md](./benchmarks.md), and the profiles are in
[optimization.md](./optimization.md). Two experiments this report relies on
are **not** in either record; §2.0 states exactly which numbers those are and
where they came from, and the staged plan re-establishes them on the record
before anything ships. The rules this design must follow come from three
places: the M9 ledger rule that every task "keeps the public API and the
recorded M6 core disposition unchanged" ([tasks.md](./tasks.md), the M9
preamble), the same commitment in
[../README.md → docs/swift/README.md](../README.md)'s "Next steps"
("behind an unchanged public API"), and
[../design/perf.md](../design/perf.md) §5, which already pre-authorizes the
mechanism in one word worth honoring: "Measured accessors may need **narrow**
`@inlinable` and `@usableFromInline` paths." The no-hard-coded-type-list rule
is this research effort's own charter, recorded here.

Nothing here is landed yet. This document is the evidence, plus a plan that a
future task graph can be cut from.

## Terms used in this report

- **Generic code** is code written once for any value type, like
  `peek<Value>`. Swift compiles it one time, in a slow, general form that
  works for every type.
- **Specialization** is when the compiler makes a custom copy of generic code
  for one concrete type, like `Int`. The custom copy is much faster.
- A **module** is one compiled unit of code. Cog is one module. An app that
  uses Cog is another. We call that app the **client**.
- **Erased** means the concrete type is hidden. When `Int` enters a generic
  function, the function only knows it has "some type." The type is erased.
- `@inlinable` is a Swift attribute. It ships a function's body along with the
  library, so the client's compiler can see inside it and specialize it.
- `@usableFromInline` marks an internal thing so `@inlinable` code may name
  it. It does not ship the body.

## 1. The conclusion up front

**A stable route exists.** The recommended design is an **`@inlinable` typed
frontier over an opaque scalar core**. In plain terms:

- Every piece of arena code that touches the user's value type gets
  `@inlinable`. That includes the public read functions, the code that finds
  a value's storage slot, the code that creates storage, and
  `CogArenaValueColumn`.
- Everything else — the settle walk, edges, propagation, turns, lifetimes —
  stays hidden inside the library. That code only works with integers, so it
  gains nothing from specialization.

With this split, the client's compiler builds a fast custom copy of the typed
code for every value type the app actually uses. It works for any type,
including the app's own structs. No type list. No unstable attributes. No
public API change.

**How much do we expect to win back?** Almost all of the measured ceiling.
The ceiling experiment (§2.0) cut PERF-03's build time by about 49%. A small
test project built for this report (§2.3) got 4.4× faster with this design.
We set the pass bar at 20% to be safe, but we expect 40% or more.

**The main cost, plainly:** the annotated code becomes visible to every app
that uses Cog. Its bodies ship with the library. Its private helpers — and
the stored properties its bodies touch — must become `@usableFromInline`
internal. Every app binary carries one custom copy of that code per value
type. And the code must work correctly when any client's compiler optimizes
it — so release-mode testing becomes critical, and we must measure code size
and build time instead of assuming they are fine.

## 2. Evidence

The evidence comes from four places: two experiments run for this effort that
are not yet in the measurement record (§2.0), the Swift compiler's own source
and documents (§2.1), how major Swift libraries handle this (§2.2), and one
controlled probe built for this report (§2.3). Facts are labeled apart from
inference.

### 2.0 Provenance: two experiments that are not yet in the record

Both experiments below were run on 2026-08-20 on this host — `mactop`, Apple
M4 Pro arm64, Xcode 26.4 (17E192), Apple Swift 6.3, an idle machine, with
PERF-03's exact measured boundaries — and both were fully rolled back
afterward. **Neither was entered into benchmarks.md or optimization.md.**
Their only trace is obsolete jj revisions. Until stage 1's control arm
re-establishes them on the record, every number in this subsection carries
that caveat.

**The ceiling experiment.** Temporary `@_specialize(exported: true, where
Value == Int)` was placed on the three public entry points PERF-03 actually
uses (with the two subscripts converted to explicit getters, since the
attribute is rejected on subscripts), on top of five internal column-method
annotations. Symbol inspection confirmed the benchmark binary called all
three exported fast copies. Three process-level runs per side:

| Measure                   |                 baseline |              specialized |                             change |
| ------------------------- | -----------------------: | -----------------------: | ---------------------------------: |
| PERF-03 p50 (three runs)  | 2,261 / 2,335 / 2,247 µs | 1,161 / 1,137 / 1,172 µs | **48.65% faster** (median of runs) |
| instructions (median)     |                     55 M |                     26 M |                       52.73% fewer |
| `M9-01` build allocations |                    5,697 |                **1,699** |                       70.18% fewer |
| `CogGraph` file size      |              6,733,200 B |              6,758,208 B |                            +0.371% |
| Mach-O `__text`           |                        — |                        — |                            +0.369% |

The 5,697 baseline allocation count is also recorded in
[benchmarks.md](./benchmarks.md) (`M9-26`); the 1,699 exists only here. An
earlier variant of the same experiment, with the five internal annotations
but no exported public entries, produced fast copies that nothing called;
§3 explains why.

**The keyed descriptor-location cache.** Before the ceiling experiment, a
cache of the resolved typed column and record index per descriptor and
context was tried, so keyed families could skip the repeated erased lookup
and cast. PERF-03 moved from a p50 of 2,347 µs to 2,318 µs — about 1.2%,
with overlapping distributions — while adding real cache, context, release,
and teardown invariants. It was fully rolled back. This is distinct from
`M9-23`'s **keyless** memo, which shipped and is endorsed by the record;
the keyed variant is the one that failed to pay.

### 2.1 The rules that decide everything

- **R1 (fact).** A client can only specialize a library function if the
  function's body ships with the library. `@inlinable` is the supported way
  to do that. `@usableFromInline` alone does not ship a body.
  ([SE-0193](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0193-cross-module-inlining-and-specialization.md))
- **R2 (fact).** Specialization flows downward from a call site that knows
  the concrete type. If a caller only has an erased type, the shipping
  compiler's default pipeline does not specialize the call — partial
  specialization exists but sits behind a default-off flag
  ([Generics.cpp](https://github.com/swiftlang/swift/blob/main/lib/SILOptimizer/Utils/Generics.cpp)).
  So code that is only ever reached from generic code stays slow on this
  path.
- **R3 (fact + inference).** Release builds already turn on a conservative
  automatic version of body-shipping ("default CMO"). But it declines to
  ship the body of a public function that touches internal code — with
  narrow carve-outs, such as internal class methods
  ([CrossModuleOptimization.cpp](https://github.com/swiftlang/swift/blob/main/lib/SILOptimizer/IPO/CrossModuleOptimization.cpp)).
  That `Cogs.peek` gets no help today is fact. That this is _why_ the build
  path loses 2.2× is this report's inference — the record's own words are
  that the cost is "the erased-storage crossing, not the layout"
  ([optimization.md](./optimization.md), `M9-26`), and the two statements
  fit together: the crossing is slow because nothing can specialize it.
- **R4 (fact).** Swift 6.3 shipped a new stable attribute,
  [`@specialized` (SE-0460)](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0460-specialized.md).
  It does not help here. Its fast copies are internal only: clients still
  make a slow generic call, and a runtime type check inside the function
  picks the fast copy. Letting clients call the fast copies directly is
  listed as future work.
- **R5 (fact).** The ceiling experiment's attribute,
  `@_specialize(exported: true)`, works differently: the client's optimizer
  rewrites calls to point straight at the library's pre-built fast copies,
  and the compiler source shows it skips every non-exported attribute. This
  is exactly why the experiment worked. The attribute and its machinery
  predate it, but the modern spelling with `exported:` arrived in
  [PR #6797](https://github.com/apple/swift/pull/6797) — and the whole
  family remains underscored and unstable.
- **R6 (fact + inference).** A non-exported fast copy can only be reached
  through a type check the compiler inserts inside the generic function — and
  the pass that inserts those checks does not handle some function shapes and
  skips copied-in code
  ([EagerSpecializer.cpp](https://github.com/swiftlang/swift/blob/main/lib/SILOptimizer/Transforms/EagerSpecializer.cpp)).
  Fast copies nothing points at get stripped out of the binary. That matches
  the failed internal-only variant exactly.
- **R7 (fact + probe).** Closures follow the same rule as calls. A closure
  created where the type is concrete gets a fast body, and it keeps that fast
  body even when it is stored behind an erased reference and called later. A
  closure created inside generic code stays slow on this path — it can only
  become fast if its enclosing context is itself later specialized or inlined
  into a concrete caller, which never happens to Cog's registration code
  today.
- **R8 (fact).** Build flags cannot save us. SwiftPM refuses `unsafeFlags` in
  packages that consumers depend on by version, and "Package CMO" only works
  inside a single package, never across to a consumer.
- **R9 (inference, well-grounded).** For a source-only package like Cog, the
  scary ABI warnings around `@inlinable` do not apply — every app recompiles
  Cog from source on every update. The real costs are: internals become
  visible, app binaries grow per type, client builds take longer, and the
  annotated bodies become behavior the ecosystem depends on.
- **R10 (fact).** The record buckets the arena's build cost as 28.6% in
  "generic metadata + witness tables" and 30.5% in "unspecialized generic
  value work" ([optimization.md](./optimization.md), `M9-26`). Both are
  taxes that specialization removes: the first is paid resolving type
  information at runtime, the second is paid running value operations
  through general helper routines instead of direct loads and stores.

### 2.2 What mature libraries do

- **swift-collections** is the closest model. Nearly its whole implementation
  is annotated — 2,472 uses of `@inlinable` on `main` as of 2026-08, a
  moving number — precisely because it is a source package, not a binary
  one. Two lessons transfer: any `_modify` accessor must also get
  `@inline(__always)` or clients pay a heap allocation per access
  ([#164](https://github.com/apple/swift-collections/issues/164)); and this
  style conflicts with binary "library evolution" builds
  ([#676](https://github.com/apple/swift-collections/issues/676)).
- **SwiftNIO** splits its world the way this design does: the data path
  (`ByteBuffer`) is fully `@inlinable`, while handler dispatch in
  `ChannelPipeline` is existential and unspecializable by design — the
  pipeline file carries a few annotations, but the event path runs on
  dynamic dispatch.
- **Apple's Observation framework** shows the opposite pole. It ships as OS
  binary, so it cannot use `@inlinable` at all. It stays fast by making its
  erased hub do almost nothing, and by using a macro to generate the per-type
  hot code inside the client's own class. Cog already gets that benefit in
  one place: selector bodies are client closures.
- **The Composable Architecture** annotates its reducer chain and erases
  once at the store. Warning story: a compiler bug caused release-only
  crashes in a deep inlined generic chain, worked around with
  `@_optimize(none)`
  ([PR #3683](https://github.com/pointfreeco/swift-composable-architecture/pull/3683)).
  Release testing matters.
- **Nobody ships the closure-table trick.** No surveyed library forms
  specialized closures at registration and stores them erased. The mechanism
  is sound (R7, and our probe proves it), but Cog would be first.
- **swift-state-graph**, the library Cog benchmarks against, uses no
  performance attributes at all and erases immediately. Against the simple
  core it is 5–5.5× slower on the diamond and deep shapes and about 3× on
  broad and unstable ([benchmarks.md](./benchmarks.md), `M6-11c`).

### 2.3 The controlled probe

For this report we built a small, throwaway test project (outside this
repository) that copies Cog's exact structure: generic descriptors, a typed
`Column<Value>` stored erased inside a record, a stored recompute closure
created by generic registration code, a plain integer core with a settle
walk, and public generic `peek` and `get` functions. A client shaped like
PERF-03 (500 keyed sources plus 500 keyed derived values, fresh context every
run) drove two versions whose source differed only in attributes. The probe
ran on this machine's Xcode 26.4 / Swift 6.3 — note that the repository's CI
pin is Xcode 26.6, so stages 1–4 must run on the pin, not on this probe's
toolchain.

| Version                             | Int build p50 | user-struct build p50 | fast copies in the client binary |
| ----------------------------------- | ------------: | --------------------: | -------------------------------: |
| plain (today's Cog shape)           |      1,090 µs |              1,069 µs |                                0 |
| frontier (`@inlinable` typed slice) |    **247 µs** |            **202 µs** |                               29 |

The frontier client binary contains custom fast copies — for a struct the
library has never seen — of the whole chain: slot lookup, storage creation,
column commit and growth, recompute, and most importantly the stored
recompute closure itself. The plain integer core later calls that closure as
a simple function pointer and lands in fast code. The slow generic entry
points also stay in the binary, and a debug build of the client still works
correctly. So the fallback is automatic. Size cost: the client binary grew
31 KB for two specialized value types.

Two things we could not confirm: whether Swift 6.3's `@specialized` works on
subscripts (the proposal does not say; it does not matter for this design),
and any published numbers for how much `@inlinable` slows client builds —
stage 4 below measures that here.

## 3. Where PERF-03's time actually goes

PERF-03 builds a graph of 1,000 keyed states. The benchmark lives in its own
package with its own module, so it crosses a real module boundary into Cog
the way an app does — though it depends on Cog by local path, deliberately
never by version, which also means it is exempt from the `unsafeFlags` rule
R8 cites. The specialization argument only needs the module boundary, which
is genuine.

For each key it runs two statements. Here is what happens to the type
information in each:

**Statement A — `context.peek(entrySourceCogs[key])`:**

1. In the client, `entrySourceCogs[key]` makes a `ManualCog<Int>`. The
   compiler knows it is `Int`. This is the last moment it knows.
2. The call enters `Cogs.peek<Value>` (`Cogtext.swift`). The type is now
   erased. `peek` is not `@inlinable`, and the automatic system cannot ship
   it (R3), so everything below runs as slow generic code.
3. Cog looks up the descriptor's record and casts its erased column back to
   `CogArenaValueColumn<Value>`. That cast asks the Swift runtime for type
   metadata the caller already knew. PERF-03 is fully keyed, so the `M9-23`
   memo that skips this for keyless state never fires. The profile shows
   this cast is one of the biggest costs.
4. On the first touch of each descriptor, Cog creates the column with its
   `equals` closure, and creates the record's `commitSource` and
   `removeValue` closures — inside generic code. By rule R7, those closures
   are slow for the record's whole life.
5. `column.insert` grows and writes `ContiguousArray<Value?>` cells in slow
   generic form: every cell touch pays helper-routine copies and `Optional`
   bookkeeping through metadata (R10).

**Statement B — `context[entryCogs[key]]`:**

1. The observed derived subscript erases the type at entry, same as before.
2. Cog resolves the derived record the same way, and creates the record's
   stored `recompute` closure inside generic code — so it is slow for the
   record's whole life.
3. `settle` runs. It is plain integer code and is already fine. It calls the
   stored `recompute` pointer.
4. `recompute<Value>` runs the selector. Inside the client's selector
   closure the type is concrete again — but the very first read
   (`c[entrySourceCogs[key]]`) crosses back into the library and erases it
   again.
5. `column.stage` and `column.commit` finish in slow generic form.

In short: the concrete type exists in exactly two places — client call sites
and the inside of client selector closures — and dies at every public entry.
Each library layer then re-derives, at runtime, what the caller's compiler
already knew. (The `AnyHashable` key hashing, 9.3% of the time, is a settled
separate decision and not part of this design.)

**Why the two experiments in §2.0 behaved as they did.** The internal-only
variant failed by rule, not by luck: no call site anywhere knew a concrete
type (R2), the client-side rewrite ignores non-exported copies (R5), and the
only other path to them is a type-check mechanism that does not cover these
function shapes (R6). The fast bodies had no callers, so the linker stripped
them. The exported variant worked because it fixed both problems at once:
clients got direct targets to call, and inside Cog each exported fast entry
was compiled knowing `Value == Int`, so the compiler specialized everything
below it — including the closures, which is why recompute got fast too. The
49% was never about two arrays. It was about restoring a known type at the
top of the chain. This design restores it on the client's side instead, for
every type instead of a listed few.

## 4. The options, ranked

| Rank | Option                                        | any `Value`? | stable?        | expected win           | main cost                                    |
| ---: | --------------------------------------------- | ------------ | -------------- | ---------------------- | -------------------------------------------- |
|    1 | **A. inlinable typed frontier**               | yes          | stable         | ~80–100% of the ~49%   | visible implementation; per-type binary size |
|    2 | B. specialized closure table at registration  | yes          | stable         | ~30–50%                | new moving parts; lookups stay slow          |
|    3 | C. `@specialized` (SE-0460) with a type list  | **no**       | stable         | small                  | type list; callers stay slow by design       |
|    4 | D. `@_specialize(exported:)` with a type list | **no**       | **unstable**   | ~100% for listed types | unstable compiler dependency                 |
|    5 | E. raw-byte columns with helper tables        | yes          | unsafe         | ~30% at most           | hand-managed memory around user types        |
|    6 | F. macro-generated fast paths                 | yes          | stable         | same as A, never more  | new user-facing syntax for zero added power  |
|    7 | G. build flags (aggressive CMO, Package CMO)  | —            | not deployable | —                      | SwiftPM rejects them for versioned consumers |

**A (recommended):** attributes only, zero public API change, and no new
runtime state, cache, or invalidation. That last point matters because this
effort has already paid for the alternative once: the keyed
descriptor-location cache (§2.0) bought about 1.2% for a real spread of new
lifecycle invariants and was rolled back, and the record separately declined
`unsafeDowncast`'s 5% because it traded a clear failure for undefined
behavior ([optimization.md](./optimization.md), `M9-12`). Option A adds no
state that can go stale and no cast that can go wrong; its costs are
annotation noise, promoting the frontier's private helpers **and the stored
properties its bodies touch** to `@usableFromInline`, and code-size and
build-time growth that must be measured (about 15 KB per type in the probe;
+0.371% file size for three fast copies in the ceiling experiment). If Cog
ever ships as a binary framework, this choice must be revisited.

**B (the fallback):** make only the registration path `@inlinable`, capture a
table of fast closures when a descriptor is first used, and have the normal
read path call the stored pointers. It works for any type (R7). But the read
path would still pay the erased cast and metadata lookup on every keyed
access, and the table is the same species of per-descriptor lifecycle state
that made the keyed cache not worth 1.2%. Held in reserve if A's cost gates
fail.

**C and D:** both need a list of types, which this effort's charter forbids
as the general design. C also cannot help callers by design. D reproduces
the experiment but rests on an unstable attribute — a research aid only,
worth revisiting if Swift ever stabilizes exported fast copies.

**E, F, and G:** raw byte storage solves density, not specialization, and
puts user values under hand-managed memory. Macros cannot reach inside
another module, so anything they generate must call `@inlinable` entries
anyway — option A with extra syntax. Build flags cannot be required of
consumers.

## 5. The recommended design

### 5.1 Where the line goes

The arena already separates code that touches `Value` from code that only
touches integers. The design annotates exactly the first group and stops:

| Tier         | Treatment                                        | What is in it                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| ------------ | ------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **frontier** | `@inlinable` — body ships; clients specialize it | the two arena `#if` branches of `Cogs.peek` — the manual and derived overloads; the async overload just delegates and needs nothing — plus the observed subscripts; `Reader`'s subscripts, peeks, and `curr`; the `Writer` staged path; `CogArenaCore`'s typed methods — the value reads, the four location resolvers, `manualRecord`, `derivedRecord` (closure creation included), and `recompute<Value>`; all of `CogArenaValueColumn`; the descriptor memo accessors; and the two tiny scalar validators `CogArenaStorage.index(of:)` and `contains(_:)` |
| **opaque**   | `@usableFromInline` — callable, but body private | `settle`, dependency capture and recording, `installSlot`, `makeRecord`, the propagation and edge storage, the observation flush, the lifetime engine, turn machinery, `allocate` and `release`. None of this touches `Value`; inlining it buys nothing and would freeze parts of the core still being measured                                                                                                                                                                                                                                             |
| **types**    | `@usableFromInline`, `@frozen` where it helps    | every type a frontier body names: the column, record, core, storage, slot, identity, key, and label types, and the descriptor classes. Note this includes their **stored properties** — an `@inlinable` body can only touch `@usableFromInline` fields, so the columns' arrays and the record's closures get the attribute too, and with it the repository's doc-comment obligation for internal-and-up declarations. The async path is left out of stage 1; it is not on PERF-03's path                                                                    |

### 5.2 Simple-core builds stay untouched

Today the accessors hold `#if COG_CORE_ARENA` inside one body. Moving the
split outside the declaration lets the arena build get the attribute while
the shipping simple core does not change at all:

```swift
#if COG_CORE_ARENA
@inlinable
public func peek<Value>(_ valueReference: ManualCog<Value>) -> Value {
  let value = arenaCore.manualValue(for: valueReference)
  arenaCore.scheduleLifetimeReleaseIfUnobserved(for: valueReference, in: self)
  return value
}
#else
public func peek<Value>(_ valueReference: ManualCog<Value>) -> Value { … }  // unchanged
#endif
```

`#if` blocks inside an `@inlinable` body are resolved when the _library_ is
compiled, so a client never sees the branch that was not selected. The simple
core has its own version of this problem — `M9-12` measured 18.6% of its
steady turn in metadata lookups — and the same pattern would work there
later. That is a separate decision this design does not force.

### 5.3 The one detail that carries the design

`manualRecord(for:)` and `derivedRecord(for:)` must be `@inlinable`
_including the closures they create_. That is what makes the record's stored
`recompute`, `commitSource`, and `removeValue` pointers refer to fast,
client-built code — so the plain integer `settle` walk, which never learns
the type, dispatches straight into fast bodies:

```swift
@inlinable
internal func derivedRecord<Value>(for descriptor: DerivedCogDescriptor<Value>)
  -> (record: CogArenaDescriptorRecord, column: CogArenaValueColumn<Value>) {
  if let record = recordsByIdentity[descriptor.identity] { … }  // fast path, client-specialized
  let column = CogArenaValueColumn<Value>(in: arena, equals: { descriptor.valuesAreEqual($0, $1) })
  let record = makeRecord(  // opaque and non-generic — stays inside the library
    …,
    recompute: { core, cogs, slot, key in  // created HERE, in client-compiled code →
      core.recompute(descriptor: descriptor, column: column, slot: slot, key: key, in: cogs)
    })  //   so the stored pointer refers to a fast body
  return (record, column)
}
```

Without this piece, first settlement — half of PERF-03 — stays slow no matter
what else is annotated. The probe showed exactly this fast-closure symbol
appearing in the client binary.

### 5.4 What happens when specialization does not apply

Nothing needs designing, because the fallback is automatic. The library keeps
its compiled slow generic entry points for every frontier function (the probe
verified this). A debug build, a compiler that declines a given
specialization, or any future resilient setup simply calls today's generic
code, with today's speed and identical behavior. Users never do anything.

### 5.5 How this fits the repository's standing rules

- **The `nonisolated deinit` rule stands.** Whether trivial frontier deinits
  also want `@inlinable` (swift-collections does this) is a stage-1
  measurement question, not a default.
- **Yield-once accessors:** no frontier declaration has a `_modify` or
  `read` accessor today — `Writer`'s subscript is a plain `get` and
  `nonmutating set`. The rule to carry forward is preventive: no frontier
  accessor may _gain_ a yield-once accessor without pairing `@inlinable`
  with `@inline(__always)`, or clients allocate on every access
  (swift-collections #164). PERF-06's exact-zero allocation gate is the
  backstop.
- **`@exclusivity(unchecked)`:** the attribute travels with the shipped
  bodies, but stage 1 must confirm no `swift_beginAccess` calls reappear in
  the clients' fast copies. Quietly losing `M9-22`'s 21% would be easy to
  miss.
- **Isolation:** shipped bodies carry the library's resolved MainActor
  isolation, and the four-leg test matrix proves client settings cannot
  change it. But `M9-01` measured dynamic isolation checks at about 12% of a
  turn, so stage 1's disassembly pass also asserts that no executor-check or
  executor-hop calls appear in the clients' fast copies — the same treatment
  the exclusivity markers get.
- **Documentation and lint:** newly `@usableFromInline` declarations —
  including the promoted stored properties from §5.1 — are still `internal`,
  so they already fall under the doc-comment rule, and `mise run lint:swift`
  must stay green over the widened surface.
- **Scenario purity:** attributes are invisible to tests. COUNT-09 through
  COUNT-11 stay the semantic gate.

### 5.6 What Storefront should show

Storefront uses many more value types than PERF-03's `Int`-only graph, which
makes it the honest test of the per-type size cost: every distinct `Value`
adds one custom copy of the frontier to the app binary. Expected results: the
arena's build-heavy cuts (cold start, footprint) improve, because they are
exactly the keyed path the memo cannot cover; the steady cuts move less; the
simple core does not change at all. The app binary's code size and the UI
suite's launch time decide whether the per-type cost is acceptable at real
app scale.

## 6. The staged proof plan

Each stage is a separate, reversible experiment on a temporary jj revision
that is abandoned if its gate fails. No stage edits documents until stage 5.
Stage 0 is already done. Stages 1–4 run on the repository's pinned Xcode,
not on the toolchain that ran the probe.

| Stage   | Experiment                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         | Pass / fail                                                                                                                                                                                                                                                                                                                                     |
| ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **0** ✓ | The throwaway two-package probe (outside the repository): mechanism, arbitrary types, closure specialization, fallback.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | Passed: 4.4× faster; 29 fast copies in the client, including the stored closure; debug fallback works.                                                                                                                                                                                                                                          |
| **1**   | **The mechanism on real Cog, with a control arm.** Annotate the minimal §5.1 slice under `COG_TEST_CORE=arena`. Run PERF-03 three ways with `M9-25`'s method — **seven paired runs**, identical boundaries: today's baseline, the frontier, and a temporary `@_specialize(exported:)` control arm that re-establishes §2.0's ceiling **on the record** with the pinned toolchain's environment. Prove with `nm` and disassembly on the `CogGraph` binary: fast copies exist for the chain including the record closures; no `swift_beginAccess` and no executor-check or hop calls in the fast copies; the generic entries still exist. Also run the `M9-01` build workload for allocation and instruction counts. | **Pass:** frontier at least 20% faster p50 (expecting 40%+, and comparable to the control arm); instructions down by a similar amount; allocations at or below baseline, compared against the control arm's re-measured count rather than §2.0's unrecorded 1,699. **Fail:** stop; choose between option B and keeping the arena research-only. |
| **2**   | **Behavior.** `mise run test:cores`, `test:matrix` (all four legs), `test:release`, `test:value-references`, `test:compilefail`, and `test:simulator` — the boundary suite matters here because the observed subscripts are on the frontier, and the simulator leg is where client-compiled inlined bodies meet `@Observable` tracking. The release leg matters most: this repository's own optimizer crashes and TCA #3683 both lived there.                                                                                                                                                                                                                                                                      | Every suite green with unchanged executed-test counts. Any behavior change is an automatic fail.                                                                                                                                                                                                                                                |
| **3**   | **Breadth.** The full benchmark suite on both cores (the four whole-graph shapes need a fresh run anyway); the five Storefront headless cuts on both cores after `mise run test:storefront`; the PERF-06, pinned-key, and steady-turn gates.                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | Steady turn, pinned keys, and PERF-06's exact zero unchanged within noise on both cores; no Storefront cut more than 5% worse; simple-core numbers unchanged by construction.                                                                                                                                                                   |
| **4**   | **Cost.** Code-size (`__TEXT`/`__text`) for the `CogGraph` binary and the Storefront app, release, both cores; clean-build times for the benchmarks package and the app; the Cog swiftmodule size (informational). One release-_archive_ build of the Storefront app, since that configuration is where TCA #3683 bit.                                                                                                                                                                                                                                                                                                                                                                                             | `CogGraph` code at most +10%; the app at most +5%; clean builds at most +25% (benchmarks) and +10% (app); the archive build succeeds and launches.                                                                                                                                                                                              |
| **5**   | **Recording and landing.** Write the results — including the control arm's re-established ceiling — into [optimization.md](./optimization.md) and [benchmarks.md](./benchmarks.md) in house style; document how to re-verify in the `M9-01` probe. On the final squashed revision, re-run the stage-2 behavior gates plus `mise run lint:swift`, `fmt:check`, and `tasks:check`. Cutting the task graph carries the repository's pairing rules with it: a plan.md milestone, its scenarios, the ledger tasks, and the GitHub issue mirror land together. Optionally add an advisory (never gating) script that checks the fast-copy symbols — advisory because symbol names are not a stable contract.             | All gates green on the landing revision, and the paired documents land in the same revisions that make them true.                                                                                                                                                                                                                               |

Across every stage, the DocC public symbol list must not change — attributes
only, no new API. That holds the M9 no-API-change rule by construction and
checks it by machine.

**What passing unlocks.** This plan deliberately ends in a decision, not just
a number. The recorded reason the simple core remains the shipping default is
`M6-12a`'s disposition, and the standing entry in
[benchmarks.md](./benchmarks.md) names the 2.2× build gap as one of the two
shapes the arena still loses. If stages 1–4 pass, that reason materially
weakens, so stage 5's landing must also charter an `M9-18`-style decision
task that reweighs the core disposition with the new build numbers beside the
arena's standing warm-path and Storefront wins — including whether the arena
is promoted, what evidence (the pinned-CI Storefront rerun, the UI suite
rerun) is still owed first, and whether any release is warranted. If stage 1
fails, the same decision task records the fallback order from §7 instead.
Either way, the outcome is a recorded decision, not a fast research core with
no charter.

## 7. Open risks, and what to do if this fails

- **Release-mode compiler bugs** (needs proof): deep inlined generic chains
  hit a compiler bug causing release-only crashes this cycle (TCA #3683), and
  this repository's own `deinit` crashes say the risk is real. Answer: stage
  2's release leg, plus stage 4's release-archive build of the Storefront
  app, not just `swift build -c release`.
- **Per-type binary size at app scale** (needs proof): about 15 KB per type
  in the small probe; Cog's frontier is bigger and Storefront has many
  types. Stage 4 owns this. The escape valve is a hot/cold split — mark cold
  record creation `@inline(never)` and keep it opaque — trading a little of
  the build win for size.
- **Frozen behavior in practice:** shipped bodies are rebuilt on every
  release, but their visible behavior becomes something client builds bake
  in. Treat the frontier as part of the versioning contract and keep it as
  small as stage 1 proves sufficient — perf.md's word is "narrow."
- **What this design does not fix:** the `AnyHashable` key hashing (9.3%, a
  settled layout choice) and uncoordinated column growth (6.8%; worth its own
  small experiment later). Both stay on the issue #373 backlog.
- **If stage 1 fails its gate**, fall back in this order: (1) option B's
  registration-time closure table — stable, smaller surface, partial win;
  (2) keep the arena as a research core — its warm-path and Storefront wins
  stand without this — and revisit when Swift stabilizes exported fast
  copies, which would make the ceiling experiment's exact mechanism stable;
  (3) a small, clearly documented `@_specialize(exported:)` list stays
  available for benchmark research only, labeled as an unstable compiler
  dependency, never shipping policy.

## Appendix: the twelve chartered questions

| #   | Answer                                                                                                                                                                                                                             | §          |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- |
| 1   | The exported experiment gave clients direct fast targets (R5) _and_ gave the library a known type to specialize everything below, closures included. The internal experiment provided neither.                                     | §3         |
| 2   | The concrete type dies at each public entry and is re-derived by a runtime cast in the record lookups; it briefly returns inside client selector closures and dies again at `Reader`'s boundary.                                   | §3         |
| 3   | Yes — SE-0193 body shipping is the stable mechanism, and the probe proved client-side specialization of the full chain for a struct the library had never seen, across a real module boundary.                                     | §2         |
| 4   | For a source package, nothing becomes binary ABI; the frontier's bodies and names become visible, version-contract surface. A future binary distribution would make the frontier real ABI.                                         | §2.1, §7   |
| 5   | Yes, proven rather than guessed: a closure formed where the type is known stays fast behind erased storage; and a table formed inside generic library code stays slow on every path Cog actually has.                              | §2.3, §5.3 |
| 6   | Yes. `#if COG_CORE_ARENA` resolves when the library compiles, and the whole-declaration split keeps simple-core builds byte-identical while arena accessors specialize.                                                            | §5.2       |
| 7   | A macro adds no power: it cannot reach inside another module, so whatever it generates must call `@inlinable` entries anyway. Rejected.                                                                                            | §4         |
| 8   | No — `@_specialize` is not the only practical route. SE-0193 is, and it covers all types. The unstable attribute survives as stage 1's control arm and a possible future complement, never as policy.                              | §4, §6     |
| 9   | Expect 80–100% of the ~49% ceiling on PERF-03, with the ceiling itself re-established on the record by stage 1's control arm; the 20% gate is deliberately cautious.                                                               | §2.0, §6   |
| 10  | Types that do not specialize behave exactly as today: the generic entries remain compiled and linked, so the fallback is automatic, invisible, and behavior-identical.                                                             | §5.4       |
| 11  | The arena's build-heavy cuts improve; steady cuts move less; the simple core is untouched; Storefront's wide range of value types is the decisive per-type size test.                                                              | §5.6       |
| 12  | The existing machinery is the gate: the cross-core behavior suite, the four-leg matrix, the release and simulator legs, the compile-fail fixtures, PERF-06's exact zero, unchanged test counts, and a machine-checked symbol diff. | §6         |
