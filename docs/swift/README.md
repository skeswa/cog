# Cog for Swift

Cog is a state library for SwiftUI. It updates only the values and views that
depend on changed state. At the UI edge it works with Apple's `@Observable`
system; inside it uses its own MainActor graph.

This file is the map for the Swift design. The documents share section
numbers, so a reference such as §6.4 works across files.

## Design principles

Four principles guide every API and implementation choice:

1. **Cog should feel simple.** Declaring, reading, and changing state should
   look like normal Swift. Common code should be easy to read and reason
   about; runtime complexity stays behind the API.
2. **Every state read should be correct.** A read must match the latest
   committed source state after settling every dependency it needs. It must
   not expose a torn update, stale derived value, or half-finished change.
   Uncertain async state must be explicit in `CogPhase`.
3. **Cog should minimize runtime overhead.** Avoid needless recomputation,
   allocation, reference counting, locks, and UI updates. Measure competing
   implementations instead of guessing.
4. **Cog state should be singular.** One running app has one authoritative
   `Cogtext`, and each mutable fact represented in Cog has one writable source
   in it. Scenes, screens, and features must not create competing contexts or
   mirror sources. A test or preview is a separate runtime with one context.

Correctness and singular state are never traded for speed, and a faster
internal design must keep the common API simple.

## The documents

The design lives in [design/](./design/); the implementation effort lives in
[impl/](./impl/). Read them in this order:

1. **[dump-2026-08-06.md](../dump-2026-08-06.md): history.** Frozen notes from
   the Dart and Flutter design. They explain the original problems but do not
   define the Swift design.
2. **[design/exploration.md](./design/exploration.md): core design (§1–§5,
   §7–§11).** The graph, public API, write rules, async state, SwiftUI
   boundary, open questions, and spike plan.
3. **[design/effects.md](./design/effects.md): effects (§6).** Reactions,
   timers, lifecycle, testing, and work that can outlive the app process.
4. **[design/rx.md](./design/rx.md): Rx mapping (§5.4).** How common stream
   operators map to state dependencies, async policies, and real event
   streams.
5. **[design/perf.md](./design/perf.md): implementation and benchmarks.** The
   planned data-oriented core and the tests that must choose its physical
   layout.
6. **[impl/plan.md](./impl/plan.md): implementation plan.** The spike plan
   turned into milestones, plus the package layout, tooling, CI, and release
   process.
7. **[impl/scenarios.md](./impl/scenarios.md): test scenarios.** The
   scenario tree that drives red-green implementation: every behavior the
   library promises, written as small user stories and grouped by milestone.

## Where things stand (2026-08-09)

These choices are settled; §10 of the core document has the full record.

- `commit(_:_:)` is the only write primitive. Ops are normal `Cogtext`
  methods. `fileprivate` and `.readOnly` control which code may name writable
  state. A turn ID stops an escaped writer from writing later.
- One outer `commit` is one turn. The context moves through idle,
  accumulating, and flushing. Reactions run at the end of the turn; writes
  from reactions wait in a FIFO queue as new turns. A debug quiescence guard
  reports long causal chains through an internal diagnostic seam.
- Before notifying the UI, Cog settles every changed path that has a live
  consumer. Unused paths stay lazy.
- Refs (`Cog<T>` and `ManualCog<T>`) name state by descriptor and key. A ref
  is a value; its identity lives in an internal final-class descriptor plus
  key. Boxes create keyed refs without allocating new descriptors. The exact
  in-memory ref layout is not settled; benchmarks will compare inline keys,
  interned keys, and generic keyed refs.
- Async selectors read dependencies synchronously, then return `Work.run` or
  `Work.stream`. The first read starts work and publicly begins at
  `pending(previous: .none)`; there is no observable `initial` phase. Values
  use `CogPhase` and its `.latest` view; an explicit `Previous` case keeps “no
  previous value” distinct from “previous value was nil.” `.latest` is the
  default policy. Streams allow only `.latest`.
- `.exhaustLatest` finishes current work, then catches up once. True event
  dropping belongs to imperative ops.
- `Cogtext` owns state and reactions. Final-class `ReactionToken` and
  `EffectGroup` handles own lifecycle and cancel safely more than once.
- Production creates one app-wide `Cogtext` and injects it above all scenes.
  Screens and features share it. Tests and previews create one isolated
  context for their runtime.
- Production construction is guarded. Feature code cannot create a second
  context.
- Manual state and nodes seen by the UI live for the app context by default.
  Graph-only derived and async nodes may be released when unused. Query caches
  have their own retention rules.
- Untracked reads (`c.read` in a selector, one-shot `cogs.read` outside) skip
  the dependency edge but still settle the value they return; they are never
  stale. Exported streams (`cogs.values(of:)`) start from the current settled
  value and never make a commit wait: `.newest(1)` may skip turns for a slow
  reader, `.oldest(n)` delivers the oldest n in order and drops newer while
  full, and `.unbounded` delivers everything.
- Debug-only `seed` stages a value and pushes dirty flags like a write, but
  records no turn, sends no notices, and runs no reactions. Tests may seed
  after effects install; the next real turn settles what the seed dirtied.
- Dynamic cycles are programmer errors. Diagnostics show the keyed path.
  Synchronous selectors do not throw in v1.
- The runtime will use a data-oriented arena. Public refs remain names, never
  arena slot handles.

Still open: the read API spelling, how much `Op` support v1 needs, optional
deferred reactions, app bootstrap helpers, debug-history tools, and
persistence helpers. Ref layout, edge layout, and hash tables also remain open
until benchmarks choose them.

## Next steps

[impl/plan.md](./impl/plan.md) is the execution plan, and
[impl/scenarios.md](./impl/scenarios.md) is its test-scenario tree. Build the
simple correctness version first, then the SwiftUI boundary, then a first
async slice for a usable 0.1.0. Port `js-reactivity-benchmark` and compare ref layouts before
building the data-oriented core, and measure that core against the simple
version, swift-state-graph, and raw `@Observable`.
