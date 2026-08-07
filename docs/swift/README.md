# Cog for Swift

Cog is a state library for SwiftUI. It updates only the values and views that
depend on changed state. At the UI edge, it works with Apple's `@Observable`
system. Inside, it uses its own MainActor graph.

This file is the map for the Swift design. The documents share section
numbers, so a reference such as §6.4 works across files.

## Design principles

Three principles guide every API and implementation choice:

1. **Cog should feel simple.** Declaring, reading, and changing state should
   look like normal Swift. Common code should be easy to read and reason about.
   Runtime complexity should stay behind the API.
2. **Every state read should be correct.** A read must match the latest
   committed source state after settling every dependency it needs. It must not
   expose a torn update, stale derived value, or half-finished change.
   Uncertain async state must be explicit in `CogPhase`.
3. **Cog should minimize runtime overhead.** Avoid needless recomputation,
   allocation, reference counting, locks, and UI updates. Measure competing
   implementations instead of guessing.

Correctness is not traded for speed. A faster internal design should also keep
the common API simple.

## The documents

Read them in this order:

1. **[dump-2026-08-06.md](../dump-2026-08-06.md): history.** Frozen notes
   from the Dart and Flutter design. They explain the original problems but
   do not define the Swift design.
2. **[exploration.md](./exploration.md): core design (§1–§5, §7–§11).** The
   graph, public API, write rules, async state, SwiftUI boundary, open
   questions, and spike plan.
3. **[effects.md](./effects.md): effects (§6).** Reactions, timers, lifecycle,
   testing, and work that can outlive the app process.
4. **[rx.md](./rx.md): Rx mapping (§5.4).** How common stream operators map to
   state dependencies, async policies, and real event streams.
5. **[perf.md](./perf.md): implementation and benchmarks.** The planned
   data-oriented core and the tests that must choose its physical layout.

## Where things stand (2026-08-06)

These choices are settled. §10 of the core document has the full record.

- `commit(_:_:)` is the only write primitive. Ops are normal `Cogtext`
  methods. `fileprivate` and `.readOnly` control which code may name writable
  state. A turn ID stops an escaped writer from writing later.
- One outer `commit` is one turn. A turn moves through idle, accumulating,
  and flushing. Reactions run at the end of the turn. Writes from reactions
  wait in a FIFO queue as new turns.
- Before notifying the UI, Cog settles every changed path that has a live
  consumer. Unused paths stay lazy.
- Refs (`Cog<T>` and `ManualCog<T>`) name state by descriptor and key. Boxes
  create keyed refs. The exact in-memory ref layout is not settled; benchmarks
  will compare inline keys, interned keys, and generic keyed refs.
- Async selectors read dependencies synchronously, then return `Work.run` or
  `Work.stream`. Values use `CogPhase` and its `.latest` view. `.latest` is
  the default policy. Streams allow only `.latest`.
- `.exhaustLatest` finishes current work, then catches up once. True event
  dropping belongs to imperative ops.
- `Cogtext` owns state and reactions. Final-class `ReactionToken` and
  `EffectGroup` handles own lifecycle and cancel safely more than once.
- Manual state and nodes seen by the UI live for the context by default.
  Graph-only derived and async nodes may be released when unused. Query caches
  have their own retention rules.
- Dynamic cycles are programmer errors. Diagnostics show the keyed path.
  Synchronous selectors do not throw in v1.
- The runtime will use a data-oriented arena. Public refs remain names, never
  arena slot handles.

Still open: the read API spelling, how much `Op` support v1 needs, optional
deferred reactions, reads across `Cogtext`s, debug-history tools, and
persistence helpers. Ref layout, edge layout, and hash tables also remain
open until benchmarks choose them.

## Next steps

Build the simple correctness version first. Then add the SwiftUI boundary and
port `js-reactivity-benchmark`. Compare ref layouts before building the
data-oriented core. Measure that core against the simple version,
swift-state-graph, and raw `@Observable`.
