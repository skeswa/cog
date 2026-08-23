# Cog for Swift: test scenarios

_August 9, 2026_

This file lists every behavior Cog promises. Each short story becomes a test.
"I" means an app developer. In the LINT group, it means a developer who uses
CogLint.

## How to use this document

- Work red-green: write a failing test, see it fail, then make it pass. The
  test suite is the source of truth for pass status.
- Scenario IDs are stable. Never renumber or reuse an ID; add new scenarios at
  the end of their group. Tests should carry their scenario ID in their name
  or a comment so the suite and this tree stay linked.
- If an API name changes, update the story and test but keep the scenario ID.
  The ID names the behavior, not its spelling.
- Each group links to its milestone and design section. Exactly one task in
  [tasks.md](./tasks.md) owns each scenario through its _Greens:_ line. Section
  §6 is in [mechanisms.md](../design/mechanisms.md), §5.4 is in
  [rx.md](../design/rx.md), performance sections are in
  [perf.md](../design/perf.md), and other sections are in
  [exploration.md](../design/exploration.md).
- A scenario's proof mode says how to check it. Unit tests are the default and
  have no mark. Other modes use `(Proof: ….)`: `compile-fail`, `exit test`,
  `release configuration`, `simulator`, `floor runtime`, `suite`, or
  `benchmark`. Group 18 uses `benchmark` by default. The ledger checker makes
  each task use the right command and exact scenario set. Exit tests must run
  in debug and release. Only suite and release-configuration scenarios may
  belong to a gate.
- UI tests live in `CogBoundaryTests`, run-count tests in `CogScenarioTests`,
  and other library tests in `CogTests`. Library tests run in all four build
  legs and in release. Debug-only tests use `#if DEBUG`; the release leg proves
  those APIs are absent.
- Before tests use an ID, deleted items may be renumbered. After that, retire
  the ID and leave a gap. Never reuse it.
- A blocked behavior gets a _Pending_ note, not a guessed scenario.
- Group 18 stays open until [benchmarks.md](./benchmarks.md) records its limits
  or comparison result.

## Testing constraints

Every test follows these rules:

1. **Be deterministic.** Wait only for a signal the test controls, such as a
   test clock, continuation, refresh handle, or internal acknowledgement. Do
   not sleep, poll, retry, or allow flakes.
2. **Keep it fast.** Prefer host-side `swift test`. Use a simulator only for
   device behavior, and only in `CogBoundaryTests`. Inject time, use the
   smallest useful graph, batch compile-fail fixtures, and limit exit tests.
3. **Test behavior, not storage.** Prefer the public API, then `CogTesting`,
   debug history, and finally a narrow diagnostic seam. Do not inspect rows,
   edges, or other storage details. COUNT-09 through COUNT-11 prove that the
   same tests work across internal layouts. Group 18 is the only exception.
4. **Separate proof kinds.** Public behavior proofs in
   `CogTests` live under `Scenarios/<PREFIX>/`, and each
   `<PREFIX><IDs>ScenarioTests.swift` file contains only raw IDs from that
   scenario family. Fixtures live beside that family without a `Tests` suffix.
   Proofs that green no scenario live under
   `Infrastructure/<seam>/`, use the `...InfrastructureTests.swift` suffix,
   and use no scenario ID. Only infrastructure tests may use
   `@testable import Cog`. CogLint proofs live under `swift/Lint/Tests` and run
   with `mise run test:lint`.

## The tree

```text
 1. ONE    One app, one graph
 2. DECL   Declaring state
 3. READ   Reading state
 4. TURN   Writing state and turns
 5. GRAPH  Automatic values stay right and lazy
 6. CYCLE  Cycles and mistakes
 7. REACT  Reactions
 8. MECH   Mechanisms and timers
 9. LIFE   How long state lives
10. SEED   Test helpers: seed and stub
11. HIST   Debug history
12. UI     SwiftUI and UIKit boundary
13. ASYNC  Async values, first slice
14. POLICY Ordered async policies
15. STREAM Streams
16. EXPORT Exports and interop
17. COUNT  Run counts
18. PERF   Performance guarantees
19. LEG    Build-settings matrix
20. ACTOR  MainActor confinement
21. LINT   First-party lint tooling
```

---

## 1. ONE — One app, one graph

_Milestone M1. Design: §2.3, §6.3, §6.6._

My whole app shares one Cog world. Tests get their own little worlds.

- **ONE-01.** App assembly installs the one Cog context at launch. An op
  declared in one feature file performs a write, and a read made elsewhere
  through the installed context sees it — no other setup, no second
  context anywhere.
- **ONE-02.** Some code tries to install a second app context. Cog stops
  it right away, in debug builds and release builds, with a clear error
  saying Cog is already assembled. (Proof: exit test.)
- **ONE-03.** Feature code tries to build a plain `Cogs` with an
  initializer. The compiler says no. (Proof: compile-fail.)
- **ONE-05.** Tests and previews each ask the testing product for their own
  fresh context — two at once, then many more, one after another, with no
  app setup. Each context starts clean, a write in one is invisible to
  every other, and none of them trips the app-install guard.
- **ONE-06.** SwiftUI throws my views away and rebuilds them (a scene is
  recreated). My manual state is still there, because it lives in the app
  context, not in the views.

## 2. DECL — Declaring state

_Milestone M1. Design: §2.3, §3.1, §4._

I declare state at the top of a file and it just works.

### 2.1 Sources

- **DECL-01.** I declare a `Cog<Value>.Manual` with a starting value. When I read
  it, I get that starting value.
- **DECL-02.** I declare a `CogBox<Value, Key>.Manual` with a starting value. Each key
  I look up starts at that value, and each key holds its own value.
- **DECL-03.** I give a box a starting-value closure instead. Each key
  starts at what the closure returns for that key.
- **DECL-04.** I build `box[5]` in two different places. Both value references point
  at the same state: writing through one shows up when reading the other,
  and `box[6]` does not change.
- **DECL-05.** I expose a source through `.readOnly`. Reading the
  read-only value reference always gives the same value as the source.
- **DECL-06.** I try to write through a `.readOnly` value reference. The compiler says
  no. (Proof: compile-fail.)

### 2.2 Automatic cogs

- **DECL-07.** I declare a `Cog` that computes from other cogs. Reading it
  gives the computed value.
- **DECL-08.** I declare an automatic `CogBox`. The closure receives the key
  as a parameter and passes it to inner keyed reads by normal lexical
  capture, and each key computes with its own key.
- **DECL-09.** Declaring cogs runs nothing. An automatic cog's closure runs
  for the first time only when someone first reads it.

### 2.3 Names

- **DECL-10.** I declare a cog with a `name:`. That name appears when Cog
  talks about the cog (diagnostics and debug history).
- **DECL-11.** I declare a cog without a name. Cog falls back to the file
  and line where I declared it, rendered as `fileID:line`.

### 2.4 Selector shape

- **DECL-12.** I declare an automatic cog whose selector throws. The
  compiler says no: synchronous selectors do not throw in v1. (Proof: compile-fail.)

## 3. READ — Reading state

_Milestone M1. Design: §2.2, §2.4._

Every read I make is correct: the latest published state, fully settled.

- **READ-02.** I read an automatic cog twice with nothing changing in
  between. Its closure ran only once; the second read used the cache.
- **READ-03.** I change two sources in one turn. An automatic cog that
  combines them sees both new values together, never one new and one old.
- **READ-04.** A selector uses `c.curr` to see its own previous value and
  keeps a running total. Each turn folds the new input into the total, and
  each key of an automatic box folds with its own previous value — one key's
  fold never sees another key's total.
- **READ-05.** The very first run of a `c.curr` selector has no previous
  value, and the selector can tell.
- **READ-06.** A selector tracks a trigger and peeks at cog X with
  `c.peek`. Changing X alone does not rerun the selector. When the trigger
  later changes, the selector reruns and the peek returns X's newest
  settled value. Peeking is only ever the absence of an edge, never the
  removal of one: a selector that both tracks and peeks the same cog keeps
  the dependency.
- **READ-07.** I leave an automatic cog cold while its source changes, then
  use one-shot `cogs.peek`. It settles the automatic cog and returns its
  newest value without creating a subscription.

## 4. TURN — Writing state and turns

_Milestone M1, except TURN-15 (M4). Design: §3.2, §2.2._

`turn` is the only door for writes, and every outer call creates one named graph turn.

### 4.1 The writer

- **TURN-01.** Inside one turn, `c[countCog] += 1` works: the writer reads
  back the value it just staged, and once the turn ends every normal read
  sees the published value. (The read-after-turn half retired the former
  READ-01, whose whole assertion it is.)
- **TURN-02.** I write the same source twice in one turn. The last
  write wins, and downstream sees exactly one change.
- **TURN-03.** The writer reads a source I have not written this turn. It
  sees the current published value.
- **TURN-04.** While a turn body is still running, a normal read (not
  through the writer) still sees the old values. Staged values are
  visible only to the writer.
- **TURN-15.** While a turn body is still running, I read an automatic cog
  that is not yet settled. It settles from published values — never this
  turn's staged writes — and after the turn it recomputes from the newly
  published values.

### 4.2 Turns join, queue, and end

- **TURN-05.** A turn inside a turn joins the outer turn. Everything
  flushes once, when the outer body ends, and reactions run once.
- **TURN-06.** A turn takes its name from the op method that made it — the
  method's `#function` spelling — or from a custom name I pass. That name is
  what history shows. Joining and queueing treat names the way they treat
  turns: an inner turn that joins an outer one contributes no name of its
  own, and a turn queued during a flush keeps the name its call site gave
  it.
- **TURN-07.** I sneak the writer out of the turn — stashed in a
  variable or captured into an async task — and use it after the turn
  ended. Cog stops me with an error, in every kind of build, saying the
  writer outlived the turn that created it and that the fix is to call
  `turn` again. (Proof: exit test.)
- **TURN-08.** Several turns queue up during a flush. They run one at a
  time in the order they arrived, and each queued turn finishes
  completely — settle, notify, react — before the next one starts.

### 4.3 Equal writes are not changes

- **TURN-09.** I write a source to the value it already has. An automatic cog
  that reads it does not recompute.
- **TURN-10.** In one turn I change a value and then change it back.
  At flush time that counts as no change at all.
- **TURN-11.** I give a cog a custom `equals:`. Cog uses my rule to
  decide whether a new value counts as a change.
- **TURN-12.** A cog holds a value with no `Equatable`. Cog plays it safe
  and treats every write as a change.
- **TURN-13.** I run two sibling turns back to back in one event
  handler. Each is its own named turn: two history entries, and reactions
  run after each one.
- **TURN-14.** Inside one turn, `c[box[k]] += 1` works: the writer
  reads back the value staged for that key, and other keys are untouched.

## 5. GRAPH — Automatic values stay right and lazy

_Milestone M1, except GRAPH-13 (M4). Design: §2.2, §2.4, §5.4._

Cog recomputes only what is needed, only when it is needed, and never shows a
half-finished picture.

### 5.1 Shapes

- **GRAPH-03.** A chain deep enough to overflow a recursive walk settles
  correctly from top to bottom without exhausting the stack, once its links
  have been computed. Invalidating the source and re-settling the whole chain
  uses the iterative walk and no meaningful stack.
- **GRAPH-14.** I read the top of a very deep chain whose links have never
  been computed. Cog computes each link the first time it is read, and a
  first read that needs an uncomputed dependency computes it inline, so this
  one read nests. 128 nested cold computations succeed and the 129th fails —
  rather than exhausting the stack — with a clear error naming the chain's
  innermost links and the way out: read the chain from its source end first,
  or make it shorter. (Proof: exit test.)
- **GRAPH-04.** One source feeds many automatic cogs. Each one I read is
  right, and only the ones I read recompute.
- **GRAPH-13.** A shortcut diamond: A feeds D both directly and through B,
  so the two paths differ in length. I change A once. The arm and the join
  each recompute exactly once, and D sees A and B from the same turn —
  never new A beside old B. (The balanced diamond, the former GRAPH-02, is
  the easier case of the same invariant and retired into this one.)

### 5.2 Equal values stop the wave

- **GRAPH-05.** A middle cog recomputes but lands on the same value as
  before. The cogs below it do not recompute.
- **GRAPH-06.** A middle cog changes every time. The cogs below it keep
  following it, each link of the chain recomputing exactly once per changed
  turn — the chain-propagation story that retired the former GRAPH-01.

### 5.3 Laziness

- **GRAPH-08.** A cold cog misses ten turns of changes — the first missed
  turn alone already runs nothing, which was the whole of the former
  GRAPH-07. When I finally read it, it computes once, from the newest
  values — not once per missed turn.

### 5.4 Dependencies follow the code

- **GRAPH-09.** A selector reads cog X or cog Y depending on a switch.
  While it reads X, changing Y does nothing. After the switch flips,
  changing Y reruns the selector and changing X does nothing.
- **GRAPH-10.** A selector returns early and never reaches cog Z. Once a
  later run does read Z, changes to Z rerun the selector.
- **GRAPH-11.** A selector reads a list cog and then a keyed cog for each
  item. I remove an item from the list. That item's cog is dropped:
  changing it no longer reruns the selector.
- **GRAPH-12.** A selector reads a cog that tells it which other cog to
  read (`currentZip`, then `weather[zip]`). When the zip changes, the
  selector follows the new zip and lets go of the old one.

## 6. CYCLE — Cycles and mistakes

_Milestone M1, except CYCLE-07 (M4). Design: §2.4, perf §3.4._

If I accidentally make state depend on itself, Cog tells me exactly where.

- **CYCLE-02.** Cog A reads cog B, and B reads A. Cog fails and shows the
  whole closed path, A to B and back. A cog that reads itself — the former
  CYCLE-01 — is the one-link case of the same walk and rendering. (Proof:
  exit test.)
- **CYCLE-04.** A cycle only exists when a condition is true. Everything
  works until the condition flips; then Cog catches it.
- **CYCLE-06.** A keyed selector or its custom equality rule calls a named op
  that turns while the automatic cog is computing. Cog rejects both paths
  before the attempted turn body runs or that attempt mutates graph state,
  in debug and release. The message names the cog, key, and attempted turn and
  tells me to invoke the op outside automatic computation, from event handling
  or a reaction. (Proof: exit test.)
- **CYCLE-07.** A cycle runs through keyed cogs and reaches the real trap.
  The crash message walks the whole path with each cog's key, in debug and
  release builds, so I can see which items looped. (Retires the former
  CYCLE-03, which proved the same keyed path through the diagnostic seam
  alone.) (Proof: exit test.)

## 7. REACT — Reactions

_Milestone M1, except REACT-19 (M2) and REACT-20 (M7). Design: §3.3, §6.2,
§6.4._

A reaction watches state and does something outside the graph when it
changes. Reactions register only through a mechanism's controller (§6.2);
these stories run inside a small test mechanism's `operate`.

### 7.1 Running

- **REACT-01.** I register a reaction with `m.run`. It runs once right
  away, so Cog learns what it reads.
- **REACT-02.** A turn changes something my reaction reads. The reaction
  runs again, and it has finished before the op that published the turn
  returns — the very next line of my test can check what it did. (The
  synchronous-completion half retired the former REACT-07: under the
  no-await testing constraint, neither half is provable without the other.)
- **REACT-03.** A turn changes something my reaction does not read. The
  reaction stays quiet.
- **REACT-04.** When a reaction runs, everything it reads is already
  settled from the turn that woke it.
- **REACT-05.** I register three reactions. When a turn wakes all three,
  they run in the order I registered them.
- **REACT-06.** A reaction's reads change from run to run, like a
  selector's. It is re-tracked every run.
- **REACT-23.** While one reaction runs during a flush, it registers several
  more. Their initial tracking runs do not re-enter it: they wait behind every
  reaction already scheduled for that flush, keep registration order, and run
  before any write-back turn queued by those reactions.
- **REACT-08.** `m.watch(_, initial: .skip)` does not call me at
  registration; the first real change calls me with the old and new values.
- **REACT-09.** `m.watch(_, initial: .run)` calls me once at registration.

### 7.3 Writing back

- **REACT-14.** A reaction gets a read-only view of the graph. It cannot
  write directly. (Proof: compile-fail.)
- **REACT-16.** A reaction calls an op that turns. That write becomes a
  brand-new turn after the current flush — never a change to the turn
  being flushed (the former REACT-15, whose claim the first hop of this
  chain is) — and when A's write wakes reaction B, whose write wakes C,
  the queued turns run one at a time, first-in first-out, each seeing
  settled state.
- **REACT-17.** Two reactions deliberately wake each other for 65 turns
  and then stop. In debug, Cog warns when an uninterrupted chain passes 64
  turns — a chain of exactly 64 stays quiet — exposing the warning and its
  causal chain of turns and reactions through the diagnostic seam. The
  recorded causal chain holds at most 256 causes and says so when it
  truncates. The context is idle again before the op that started the chain
  returns — asserted directly, never awaited.
- **REACT-19.** Within one flush, every changed UI boundary is notified
  before any reaction runs — flush step 4 before step 5. (Checked through
  history or an internal seam once M2 boundaries exist.)
- **REACT-20.** Within one flush, every changed export value is offered to
  its subscriber buffers before any reaction runs — flush step 4 before
  step 5. (Checked through history or an internal seam once M7 exports
  exist.)
- **REACT-21.** A reaction watches an automatic cog. A turn changes that
  cog's source, but the recompute lands on an equal value. The reaction
  does not run: only changed reactions run in flush step 5.
- **REACT-22.** A reaction reads a manual source. I write that source to
  an equal value. The reaction does not run.

## 8. MECH — Mechanisms and timers

_Milestone M1, except MECH-11 (M4). Design: §6.2, §6.3._

Every side effect lives in a named mechanism specified at assembly; a
shorter lifetime is a `whenever` gate expressed in state. (The GROUP family —
public effect groups and reaction tokens — retired on 2026-08-14 when
mechanisms replaced them; REACT-10 through REACT-13 and REACT-18 retired with
it. Retired IDs stay retired.)

- **MECH-01.** I assemble with a list of mechanisms. Each `operate` runs
  synchronously in list order, and when assembly returns every mechanism is
  live: a turn on the very next line wakes their reactions, and reactions
  from two mechanisms run in list order when one turn wakes both.
- **MECH-02.** A mechanism configures state and seeds demand during
  `operate` through ops on its controller. Those turns settle before
  assembly returns, and a mechanism later in the list observes the earlier
  mechanism's published values during its own `operate`.
- **MECH-03.** Declaring a mechanism does nothing by itself. Its reactions
  and tasks exist only when it is listed at assembly; a mechanism left off
  the list never runs.
- **MECH-04.** Two mechanisms in one assembly list share a name. Cog stops
  assembly right away with a clear error, in debug builds and release
  builds. (Proof: exit test.)
- **MECH-05.** A mechanism without a custom `name` is known by its type name
  with a trailing "Mechanism" dropped, and every registration name composes
  under it: its `hourlyRefresh` task appears as `Weather.hourlyRefresh` in
  debug history and task names.
- **MECH-06.** An app-lifetime task started with `m.task` sleeps on the
  reusable `CogTesting.TestClock` and then calls an op every hour. When the
  clock jumps an hour, the op runs and its named turn lands in debug history.
  Before that, it does not run, and the app entry point retains only `Cogs`.
- **MECH-07.** A `whenever` gate already reads true when its mechanism
  operates. The scope body runs immediately, and its registrations are live
  when assembly returns.
- **MECH-08.** A `whenever` gate starts false and a later turn raises it:
  the scope body runs then. Another turn lowers it: the scope's reactions
  never run again and its tasks receive cancellation. A further rise runs
  the body again from scratch, with fresh registrations.
- **MECH-09.** A `whenever` scope nests inside another. Lowering the outer
  gate cancels the inner scope's reactions and tasks along with the outer
  scope's own.
- **MECH-11.** One turn both changes state a scoped reaction reads and
  lowers that scope's gate. Teardown completes safely at the scope's place
  in the flush: the woken sibling reaction in that scope never runs after
  teardown, every owned task receives cancellation, and the app's state is
  untouched.
- **MECH-12.** `Cogs.forTesting(seeding:mechanisms:)` runs my seeding
  closure before any `operate`, so an `initial: .run` watch observes the
  seeded values on its registration run instead of the declaration defaults.
- **MECH-13.** I define an op once as a `CogOps` extension. App code
  calls it on `cogs` and a mechanism calls it on `m`; both produce the same
  named turn, and the mechanism's call is attributed to its mechanism in
  debug history.
- **MECH-14.** I try to register a reaction directly on the runtime, as in
  `cogs.run { ... }`. The compiler says no: reactions register only through
  a mechanism's controller. (Proof: compile-fail.)
- **MECH-15.** I assemble with a class mechanism that owns a resource, then
  drop my own reference to the mechanism. The runtime retains that exact
  mechanism and its resource while the context lives. When the context's
  last reference drops — on the MainActor or from a background executor
  (the former MECH-10's teardown trigger) — an internal acknowledgement
  reports when deinit cleanup reached the MainActor; the scope's reactions
  and tasks are cancelled first, and only then is the mechanism released,
  and the resource after it.
- **MECH-16.** A retained class mechanism constructs its delegate-owned engine
  with a `[weak m]` callback. A callback from a background executor hops to the
  MainActor, calls an op through the controller, and records the mechanism
  attribution. After the context is torn down, the engine can invoke the
  callback again, but the controller no longer promotes, no op runs, and the
  callback does not retain the context.

## 9. LIFE — How long state lives

_Milestone M1 (UI pinning lands with M2; async release with M3; LIFE-11 with
M4). Design: §5.3, perf §7._

State lives as long as its kind says, and coming back is always safe. Grace
periods default to 30 seconds in production. Tests override that context
default and elapse it on the testing context's injected clock; no lifetime
test waits wall-clock time.

- **LIFE-01.** Nobody watches a manual cog for a long time. Its value
  survives anyway, because manual state defaults to app lifetime.
- **LIFE-03.** An automatic cog defaults to `whileObserved`. After its last
  watcher leaves and the grace period passes, Cog lets it go (the former
  LIFE-02, whose walk this contains). Read again through the same value
  reference, it comes back computed fresh — no stale previous value — with
  the correct current value, as if it never left.
- **LIFE-04.** A watcher leaves and comes back within the grace period.
  The cog was never released and did not recompute.
- **LIFE-05.** A manual cog opts into
  `whileObserved(resetToInitial: true)`. After release, the next read
  gives the starting value again.
- **LIFE-07.** A registered reaction counts as a watcher: the cogs it
  reads stay alive.
- **LIFE-08.** Once a cog has been read through the UI subscript — the read
  a view's body makes — it is pinned for the life of the app context. It is
  never released behind SwiftUI's back.
- **LIFE-09.** Automatic cog B reads automatic cog A, then both lose their last
  external consumer. Their internal graph edge does not keep them alive.
  After the grace period, reading either value reference recreates the needed states
  with the correct current values.
- **LIFE-10.** I use one-shot `cogs.peek` on a default `whileObserved` automatic
  cog. It settles current state without a durable consumer, starts or renews
  one ordinary grace window, and releases after expiry. A later peek recreates
  it from current dependencies.
- **LIFE-11.** One key of an automatic box loses its last watcher while a
  sibling key stays watched. After the grace period only that key's state is
  released: the watched key never recomputes and keeps answering warm, and
  reading the released key recreates it from current values.

## 10. SEED — Test helpers: seed and stub

_Milestone M1, except SEED-07 (M2) and SEED-08 (M4). Design: §6.6, §4._

My tests import `CogTesting` to set up state quietly with `seed`, or use a real
turn for a loud domain operation.

- **SEED-02.** Seeding is quiet in the M1 runtime: no turn lands in history
  and no reaction runs.
- **SEED-03.** I seed a source. The next read returns the seeded value (the
  former SEED-01, a precondition of every assertion here), and seeding
  marks dependents dirty: an automatic cog read after the seed recomputes
  from the seeded value. A seed obeys the source's equality rule the way a
  write does — seeding an equal value is not a change.
- **SEED-04.** The §6.6 alert story, verbatim: assemble a weather
  mechanism whose alert reaction watches for nice weather, seeding the zip
  and cloudy weather first (no alert), then stub sunny weather with a real
  turn. The alert fires exactly once, even though the reaction's first
  run never read the weather.
- **SEED-05.** `CogTesting.seed` exists only in debug builds. A release build
  has no way to seed. (Proof: release configuration.)
- **SEED-06.** I try to seed an automatic cog. The compiler says no: only
  manual sources can be seeded. (Proof: compile-fail.)
- **SEED-07.** Once M2 UI boundaries exist, I seed a source that a view has
  read. Seeding sends no UI notice; the next real turn still settles and
  notices the value dirtied by the seed.
- **SEED-08.** I call `seed` at the wrong time — inside a turn body, or
  from a selector or reaction. Cog stops me right away with a clear error
  saying seed is only for idle test setup. The guard is debug-only surface
  proven by debug exit tests; a release build has no seed at all (SEED-05).

## 11. HIST — Debug history

_Milestone M1, except HIST-06 (M2) and HIST-07 (M4). Design: §2.3, §6.2,
perf §8._

When I wonder what happened, the debug history can tell me.

- **HIST-01.** Every turn lands in history with its name — the custom name
  its call site passed, or the owning op's `#function` name when it passed
  none.
- **HIST-02.** History records writes and recomputations, and it counts the
  way the graph does: an equal write records its turn but no write entry
  and no recompute, a keyed state renders as `label[key]`, and one turn
  through a diamond records one recompute per state that actually ran.
- **HIST-03.** History is bounded: after many turns, the oldest entries
  fall off and the entry count never passes the cap. (Memory itself is
  benchmark territory, not a unit-test assertion.)
- **HIST-04.** Release builds pay nothing for history. (Proof: release configuration.)
- **HIST-05.** A watch registered with a `name:` runs. Its run lands in
  history under that name, composed beneath its mechanism's name; a
  registration without one falls back to the file and line that made it.
- **HIST-06.** Once M2 boundaries exist, history records each changed UI
  notice with the cog's human-readable label.
- **HIST-07.** Several turns queue during a flush. History shows each
  queued turn as its own entry, in execution order, and attributes every
  write to the turn that made it; entries from different turns never
  interleave.

## 12. UI — SwiftUI and UIKit boundary

_Milestone M2, except UI-16 (M4), in `CogBoundaryTests` and the Weather
example. Design: §3.4, §7, §9, perf §6._

My views update when — and only when — the values they read change. Boundary
tests assert Observation notices and re-render counters, never pixels or
wall-clock waits; real rendering is proven once by the Weather example.

- **UI-01.** A view reads a cog with `cogs[valueReference]`. When that cog
  changes, the view re-renders.
- **UI-02.** When a cog the view never read changes, the view does not
  re-render.
- **UI-03.** A card reads `weather[zipA]`. Writing `weather[zipB]`
  re-renders only zipB's card, never zipA's.
- **UI-04.** An automatic cog recomputes to an equal value, or a manual source
  is written to an equal value. Cog sends no Observation notice, and views
  reading them do not re-render.
- **UI-05.** Only cogs that a view actually read get an Observation
  boundary object. Interior graph states never do. (Checked through an
  internal seam.)
- **UI-06.** Every view that uses Cog finds the one app context directly
  through the `\.cogs` environment key. Intermediate views neither accept nor
  forward the context.
- **UI-07.** An application-owned SwiftUI binding reads the current Cog value,
  and setting it writes through a named domain turn that shows up in history.
- **UI-09.** A view uses one-shot `cogs.peek` in its body. Later changes
  to that cog do not re-render the view.
- **UI-11.** UIKit automatic tracking works through the same boundary on
  an iOS 26 simulator. (Proof: simulator.)
- **UI-12.** AppKit automatic tracking works through the same boundary on
  a macOS 26 host.
- **UI-13.** A view reads two cogs, A and B. One turn changes both. Every
  render sees either the old pair before the turn or the new pair after
  it — never one old value and one new value.
- **UI-16.** A view's first render reads cogs A and B; its next render
  reads only B. Changing A no longer re-renders the view, and changing B
  still does — each render tracks only what it read, the way GRAPH-09
  retracks a selector.

## 13. ASYNC — Async values, first slice

_Milestone M3, except ASYNC-30 through ASYNC-39 (M4). Design: §5.1, §5.2
(`.latest` only), §5.3._

Async state is honest: it always says whether it is loading, what value is
renderable, and whether any generation has succeeded.

### 13.1 Status

- **ASYNC-01.** I read a `Cog<Value>.Async` for the first time. It starts its
  work and publishes a pending turn; a `status` read returns
  `kind == .pending`, `value == default`, and `hasSucceeded == false`, while a
  value read returns that same declared resting default. There is no observable
  `initial` kind.
- **ASYNC-03.** An async cog whose value is optional succeeded with
  `nil`. When it reloads, `value` remains `nil` and `hasSucceeded` remains
  true — clearly different from the resting `nil` before any success.
- **ASYNC-30.** `kind`, `value`, `hasSucceeded`, `error`, and `isLoading` form
  the accessor set, and every accessor is right in every lifecycle state —
  the default and loading before success, the old value and loading while
  reloading, the value and not loading on success, the last good value and
  not loading on failure (the former ASYNC-04, which described the same
  walk). `kind` carries pending, success, or failure; `value` remains total
  while `error` reports only the current failure; a reload retrying after a
  failure has no error and retains its renderable value. Loading and prior
  success remain orthogonal, and a successful `nil` stays distinct from
  "never succeeded" through `hasSucceeded`.
- **ASYNC-31.** Every async cog rests on a declared default, and value reads
  are total. Every declaration states the resting value with `default:`, and
  an `Optional` spells `default: nil`. In every value spelling — `c[...]`,
  `cogs[...]`, and their peeks — the read returns the default before any
  success and the last accepted success afterward, through reload pending
  and failure alike.
- **ASYNC-32.** The `status` lens carries the same read family as the value
  spelling beside it: tracked `c.status[...]` and `cogs.status[...]` reads,
  `status.peek` one-shots, and `m.status.watch`, with identical demand,
  tracking, and lifetime rules. `CogStatus.kind` carries pending, success, or
  failure. A body first binds `let forecast = cogs.status[forecastCog]`; that
  binding observes no field, and SwiftUI Observation independently tracks only
  the `kind`, `value`, `hasSucceeded`, `error`, and `isLoading` fields the body
  later reads from `forecast`. While an equal-success reload leaves a value
  consumer quiet, the lens still shows its consumers every pending, success,
  and failure turn.
- **ASYNC-33.** The `status` lens refuses synchronous state: asking
  `cogs.status` or a selector's `c.status` for a manual or automatic cog does
  not compile. (Proof: compile-fail.)
- **ASYNC-34.** An async declaration without `default:` does not compile.
  Optional values are not special: they state `default: nil` explicitly.
  (Proof: compile-fail.)
- **ASYNC-38.** A retry after a failure fails again, even with an equal
  error. The status lens shows every turn — pending, failure, pending,
  failure, each its own turn — while value consumers stay quiet: the
  renderable value never changed, so nothing downstream reruns.
- **ASYNC-39.** Work that is still the newest run — and whose task Cog never
  cancelled — rethrows a `CancellationError` from some inner operation. That
  is an ordinary failure holding the error, never a silent forever-pending
  state; only Cog's own replacement or release cancellation publishes
  nothing (ASYNC-09, ASYNC-13).

### 13.2 Latest wins

- **ASYNC-07.** A dependency changes while work is in flight. The old
  work is cancelled and new work starts — whether the policy was spelled
  `.latest` or omitted, since `.latest` is the default.
- **ASYNC-08.** The old work finishes anyway, ignoring cancellation. Its
  result is thrown away. Only the newest run may publish.
- **ASYNC-09.** Work that was cancelled because it was replaced publishes
  no failure status.
- **ASYNC-10.** I call `cogs.refresh(valueReference)`. The work runs again even
  though no dependency changed, the status cycles again, and the returned
  handle completes only when that exact generation succeeds or fails.
- **ASYNC-11.** Only what the selector reads with `c[...]` before
  returning counts as a dependency. Values the work closure touches after
  an `await` do not retrigger it.
- **ASYNC-12.** Two keys of a `CogBox<Value, Key>.Async` fetch independently. One can
  be loading while the other has succeeded.
- **ASYNC-35.** A dependency changes while an explicit refresh's work is in
  flight. The handle resolves as `superseded` at replacement — a dependency
  change supersedes a refresh exactly as a newer refresh does — and never
  drifts forward: the superseded generation's late result publishes nothing,
  and only the dependency-started run may publish.

### 13.3 Safe release

- **ASYNC-13.** An unwatched async cog is released while its work is
  pending. The work is cancelled, and if a late result sneaks through, it
  publishes nothing. An exact refresh handle waiting on that generation resolves
  as `released` rather than hanging or following a recreated state.
- **ASYNC-14.** After a release, reading the value reference again starts fresh work
  and fresh status, unpolluted by anything from before.
- **ASYNC-37.** One key of a `CogBox<Value, Key>.Async` loses its last consumer while a
  sibling key stays watched. Grace expiry cancels and releases only that
  key's work and state: its late result publishes nothing, the sibling's work
  completes and turns untouched, and reading the released key starts
  fresh work and status.

### 13.4 Work isolation and retained values

- **ASYNC-15.** An async cog's work body runs on the MainActor by
  default. A runtime precondition inside the work proves it in every leg.
- **ASYNC-16.** Expensive work opts into `@concurrent`. It runs off the
  main actor, and its result still turns on the MainActor under the
  same generation check.
- **ASYNC-17.** The internal task that runs an async cog's work carries
  the descriptor's name and key, rendered `name[key]`, so Instruments can
  show it. (Checked through an internal seam.)
- **ASYNC-18.** Initial work throws. A status watcher and history see pending
  with the resting default and `hasSucceeded == false`, then failure holding
  the thrown error with the same pair, as two distinct turns. (The former
  ASYNC-02's published failure is this walk's second half; its
  refresh-handle outcome lives on in POLICY-06 and STREAM-07.)
- **ASYNC-19.** Work succeeds, then a dependency change starts a reload
  that fails. A status watcher and history see every visible status — the
  initial pending, success, pending with that success as its value, then
  failure with the same retained value — each as its own turn. A further
  reload's pending still carries that success — the last good value, never
  the failure.
- **ASYNC-20.** A reload succeeds with a value equal to the one it had.
  Status watchers see the pending and success turns, but value consumers see
  no change: no recompute, no re-render.
- **ASYNC-21.** I call `cogs.refresh(valueReference)` while work is already in
  flight. Under `.latest`, the in-flight run is cancelled and only the
  newest run may publish — a refresh replaces work the same way a
  dependency change does. Its exact handle resolves as `superseded` when a
  still newer refresh replaces it; it never drifts forward to that newer run.
- **ASYNC-36.** `@concurrent` work replaced by a dependency change receives
  cooperative cancellation off the actor — replacement is a stop request to
  the old task, not merely a ban on its result — and the replacement's
  result still turns on the MainActor.

### 13.5 Cold one-shot demand

- **ASYNC-22.** I use one-shot `cogs.peek` on a never-read async cog. It
  starts one suspended run, publishes
  `kind == .pending`, `value == default`, and `hasSucceeded == false`, returns
  its spelling's view — the resting default from a value peek, that pending
  status from `cogs.status.peek` — and installs no durable consumer. Another
  peek sees that same generation instead of starting a second run and renews
  its grace window. With no durable consumer, injected grace expiry cancels
  and releases the state; a late result publishes nothing, and a later read
  starts fresh work.
- **ASYNC-23.** I refresh a never-read async value reference. Refresh is one
  initial load, not a no-op or an initialize-then-replace sequence: the
  selector and work run once, one pending-with-default-and-no-success turn lands, and no
  cancellation occurs. The call installs no durable consumer and follows the
  same renewable grace and safe-release rule. A later refresh while that work
  is in flight still follows ASYNC-21.
- **ASYNC-24.** An async selector reads a source, then its last durable consumer
  leaves while work ignores cancellation inside grace. The source changes
  before that work finishes. Its now-stale result cannot clear the dependency
  invalidation; a consumer returning during grace starts work from the newest
  source value, and only that result may publish.
- **ASYNC-25.** A consumer reads only an async cog's value and then leaves.
  One injected grace window releases the internal value projection and its
  now-unobserved async dependency together, cancelling pending work without a
  second grace window.
- **ASYNC-26.** A keyed async box exposes the documented `c[forecastCogs[zip]]`
  value spelling. Equal keys share one value-projection state, different keys
  stay independent, and an equal success does not notify that key's value
  consumer.
- **ASYNC-27.** An async or automatic selector calls `cogs.refresh` while it is
  computing. Cog traps with the same clear turn-during-automatic-computation error in
  debug and release instead of starting a nested system turn. (Proof: exit
  test.)
- **ASYNC-28.** I read an automatic cog backed by an async cog through the UI
  boundary, including the documented `cogs[forecastCog]` value spelling. Its
  initial pending publication does not re-enter the automatic computation or
  flush reactions mid-computation: the read returns the current value, records
  one named pending turn, and later work completion updates it.
- **ASYNC-29.** Repeated one-shot `peek` or `refresh` demand renews an async
  state's grace while keeping at most one scheduled grace sleeper for that
  exact state. An obsolete deadline cannot release it; the latest
  demand-plus-grace deadline releases it and leaves no sleeper behind.

## 14. POLICY — Ordered async policies

_Milestone M7. Design: §5.2, §5.4._

When order matters more than speed, I pick a policy that says so.

- **POLICY-01.** After the initial run succeeds, three quick dependency
  changes under `.queue` make exactly three additional runs, one at a time
  and in input order. Each run starts only after the preceding one
  finishes, results publish in run order, and the final value matches the
  newest input (the former POLICY-02, which rode the same harness).
- **POLICY-03.** With `.exhaustLatest`, changes during a run — one or
  ten — start no new runs. When the run finishes, exactly one catch-up
  run uses the newest state.
- **POLICY-04.** With `.merged`, runs overlap, and each result publishes as
  its own turn when it lands — in landing order, not start order, so a
  slower older run that lands last is what the value shows. Order is what
  `.queue` is for; `.merged` trades it away.
- **POLICY-05.** A `.stream` selector cannot use `.queue`,
  `.exhaustLatest`, or `.merged`. The type system says no. (Proof: compile-fail.)
- **POLICY-06.** Two refreshes queue behind a settled value. The first run
  fails, publishes failure while retaining the last success, and resolves
  only its own handle as failure. The next accepted run then starts, publishes
  its own pending turn with that retained value, succeeds, and resolves only
  its own handle as success; one failure never stops the queue or strands
  later work.

## 15. STREAM — Streams

_Milestone M7. Design: §5.1, §5.2, §5.4._

Some state really is a stream — locations, sockets, database watches.

- **STREAM-01.** A `.stream` cog reports loading before its first element
  arrives (the former STREAM-02, asserted at the top of nearly every STREAM
  proof), then publishes each changed element of its sequence as its own
  turn. Watchers see every published value.
- **STREAM-03.** A dependency changes. The old sequence is cancelled and
  a new one starts; late elements from the old sequence publish nothing.
- **STREAM-04.** An unwatched `.stream` cog is released while its
  sequence is live. The sequence is cancelled, and late elements publish
  nothing.
- **STREAM-05.** A stream emits a value and then ends naturally. Ending
  publishes no extra turn or notice, starts no replacement, and leaves the
  emitted value as the current success. An explicit refresh starts a fresh
  pending generation.
- **STREAM-06.** A stream ends naturally without an element. Cog fabricates
  neither success nor failure: status remains pending on the declared default
  with `hasSucceeded == false`, no completion turn lands, and an explicit
  refresh can start a fresh generation.
- **STREAM-07.** The still-current stream throws before its first element. Cog
  publishes one failure holding the error, declared default, and
  `hasSucceeded == false`; it starts no replacement, and an exact refresh
  handle for that generation resolves as failure.
- **STREAM-08.** A refreshed stream emits an element and later throws. The
  element publishes success and resolves the exact refresh handle as success;
  the later error publishes failure retaining that value and does not rewrite
  the handle or restart the stream.
- **STREAM-09.** Cog replaces or releases a stream and iteration then throws
  `CancellationError`. Because Cog initiated that cancellation, no failure
  lands. The same error from a still-current stream Cog never cancelled is an
  ordinary published failure.
- **STREAM-10.** An `Equatable` stream yields the same value twice, then a
  different value. The duplicate creates no turn, value or status notice,
  reaction, or history entry; the later changed element publishes normally.
- **STREAM-11.** A stream value has no equality rule. Cog conservatively
  turns every element, including two whose fields happen to match, so no
  implicit reflection or event loss hides a possible change.

## 16. EXPORT — Exports and interop

_Milestone M7. Design: §8, §6.5._

Cog state can flow out as an `AsyncSequence`, and outside state can flow in.

- **EXPORT-01.** I subscribe with `cogs.values(of:)`. The first thing I
  get is the current settled value — even for a cold cog nobody has read
  before; subscribing settles it.
- **EXPORT-02.** After that, I get a value each time it changes.
- **EXPORT-03.** After consuming the initial value, I pause a default
  `.newest(1)` reader and publish A, B, then C. Its next value is settled C;
  A and B may be skipped, and none of the turns waits for the reader.
- **EXPORT-04.** After consuming the initial value, I pause an `.oldest(2)`
  reader and publish A, B, then C. It receives settled A and B in order and
  drops C; none of the turns waits for the reader.
- **EXPORT-05.** Two subscribers to the same cog own independent buffers
  and graph leases. Pausing or cancelling one neither drops values from nor
  releases the lease of the other.
- **EXPORT-06.** Cancelling the reading task releases that subscriber's
  graph lease, so a `whileObserved` cog can be let go.
- **EXPORT-07.** A view's `.task` loops over `values(of:)`. When the view
  disappears, the loop ends and the lease is gone — the §6.5 map-camera
  story. (Proof: simulator.)
- **EXPORT-08.** I link an outside `@Observable` property in with
  `c.track`. A propagation boundary is one suspension of the main actor
  after the mutation — the observation machinery fires and re-arms while
  the mutating code is off the actor. After each boundary my dependent cog
  returns the newest post-mutation value — never the pre-write value — and
  mutations made within one boundary may coalesce into a single
  propagation. (Proof: simulator.)
- **EXPORT-09.** After consuming the initial value, I pause an `.unbounded`
  reader and publish A, B, then C. It receives every settled value in order.
- **EXPORT-10.** I track one property of an outside `@Observable` object.
  Changing another property on that object does not recompute my dependent
  cogs. (Proof: simulator.)
- **EXPORT-11.** On a pre-iOS-26 runtime, the
  `withObservationTracking` shim exposes an internal acknowledgement when
  it has re-armed after an observed change. A mutation made after that
  acknowledgement propagates the newest post-mutation value. The test does
  not promise delivery for a mutation made inside the documented disarmed
  re-arm window.
- **EXPORT-12.** On an iOS 26 simulator, the `Observations` path has the
  same post-mutation value correctness and property granularity. Several
  synchronous mutations within one observation suspension boundary coalesce
  into one propagation carrying the newest value: dependents recompute once
  per boundary, not once per mutation. (Proof: simulator.)
- **EXPORT-13.** I link outside state in with `c.track`'s closure form
  instead of a key path. It has the same post-mutation value, coalescing,
  and pre-iOS-26 re-arm semantics as the key-path form. (Proof: simulator.)
- **EXPORT-14.** I subscribe to an automatic cog. A turn recomputes it to an
  equal value. Nothing is offered to my buffer: only changed values reach
  subscribers.
- **EXPORT-15.** A `whileObserved` automatic cog's only consumer is my
  `values(of:)` subscription. Grace periods come and go; the cog is never
  released while my subscription lives, and each change still reaches me.

## 17. COUNT — Run counts

_Milestones M5, M6, and M7, in `CogScenarioTests`. Design: perf §9, plan M5._

Cog never does the same work twice. These scenarios count actual selector
runs and compare them with the expected number — as plain tests, so duplicate
work fails CI even when timing looks fine. Counts come from counters the
scenarios increment inside their own selector closures — public API, no
seam — and `CogScenarioTests` may run reduced sizes of the benchmark shapes,
since expected counts derive from the parameters.

- **COUNT-01.** Kairo diamond: runs match the expected count exactly.
- **COUNT-02.** Kairo deep chain: runs match exactly.
- **COUNT-03.** Kairo broad graph: runs match exactly.
- **COUNT-04.** Kairo unstable graph: runs match exactly.
- **COUNT-05.** dynamicBench sweeps: runs match exactly.
- **COUNT-06.** Cellx lattice: runs match exactly.
- **COUNT-07.** Keyed diamonds: runs match exactly.
- **COUNT-08.** Key churn (keys added and removed over and over): runs
  match exactly, and dropped keys stop running.
- **COUNT-09.** The selection record proves every behavior scenario through M5
  passed unchanged over all three measured value-reference layouts; the suite
  remains green on the retained inline layout. (Proof: suite.)
- **COUNT-10.** The selection record proves every behavior scenario through M6
  passed unchanged when the data-oriented core replaced the simple core; the
  suite remains green on the retained arena. (Proof: suite.)
- **COUNT-11.** After M7, the complete behavior suite passes unchanged on
  the retained inline value-reference layout and arena. (Proof: suite.)

## 18. PERF — Performance guarantees

_Milestones M5, M6, M9, and M10, in the benchmark package. Design: perf §5–§9._

These checks live in the benchmark package and test the implementation itself.
Limits and layout choices stay open until [benchmarks.md](./benchmarks.md)
records data. Every item in this group uses `benchmark` proof mode.

- **PERF-01.** A steady turn — same graph shape, new values — allocates
  nothing. The retained arena reached the zero-allocation target, and the
  committed `mallocCountTotal == 0` p90 threshold is enforced by
  `bench:thresholds:check` on the pinned CI host, so the result cannot
  regress; impl/benchmarks.md records how it was reached.
- **PERF-02.** Propagation's retain and release traffic is what
  impl/benchmarks.md records. Doing none of it remains the target (perf §5).
  The drift check compares against a locally recorded baseline through
  `bench:baseline:check` — no committed threshold gates this in CI — so the
  benchmark-record entry, refreshed whenever the benchmark reruns, is the
  durable claim.
- **PERF-03.** Peak memory for a 1,000-state graph stays within the
  baseline recorded in impl/benchmarks.md. The comparison runs through
  `bench:baseline:check` against a locally recorded baseline — no committed
  threshold gates this in CI — so the benchmark-record entry is the durable
  claim.
- **PERF-04.** A graph with 1,000 states and 12 UI-read values owns 12
  boundary objects, not 1,000.
- **PERF-05.** A released state's slot is reused safely: its generation
  changes, and stale internal access is caught in debug builds.
- **PERF-06.** Building a value reference with `box[key]` allocates nothing.
- **PERF-07.** Notice traffic for pinned keyed states — old keys the UI
  once read but no longer shows — stays within the baseline recorded in
  impl/benchmarks.md. The comparison runs through `bench:baseline:check`
  against a locally recorded baseline — no committed threshold gates this
  in CI — so the benchmark-record entry is the durable claim.
- **PERF-08.** Keyed diamonds and key churn were measured under inline
  `AnyHashable`, interned-token, and generic-keyed value-reference layouts in
  one pinned environment. The recorded result selects inline `AnyHashable`;
  the rejected implementations no longer remain as build configurations.
- **PERF-09.** Mostly static and high-churn graphs were measured under the
  shared edge pool, per-state prefix arrays, and inline-plus-overflow edge
  layouts in one pinned environment. The recorded result selects the shared
  pool; the rejected implementations no longer remain as build configurations.
- **PERF-10.** The specialized arena is measured against compact arena,
  swift-state-graph, and raw `@Observable` in one pinned environment. Historical
  simple-core results remain in impl/benchmarks.md but are not a build
  configuration. The committed one-sided wall-clock ceilings are the
  thresholds, enforced in CI by `bench:thresholds:check` on the pinned host
  and proven live by the `bench:thresholds:sentinel` rejection run.
- **PERF-11.** A pinned keyed state that stops changing costs a turn
  nothing. A turn that writes and reads one key of a family performs the
  same retain and release traffic whether one key or a thousand are pinned
  beside it, and the notices it delivers keep their order. The historical
  simple-versus-arena comparison remains in the benchmark record.
- **PERF-12.** A steady turn's shared machinery allocates nothing: the turn
  boundary, the writer it hands out, and the arrays a turn accumulates into
  reuse their storage rather than being rebuilt. The recorded steady-turn
  allocation count falls to what impl/benchmarks.md records and only ever ratchets
  downward.
- **PERF-13.** Settling one node of a deep chain costs what impl/benchmarks.md
  records and no more — allocations, retains, and releases per node — and
  the committed per-node threshold, enforced by `bench:thresholds:check`,
  keeps that cost from regressing.
- **PERF-14.** After the shared machinery work, the historical simple core,
  compact arena, and specialized arena were compared on steady, deep, broad,
  and unstable shapes in one environment. impl/benchmarks.md records the
  comparison; only the specialized default and public `CompactArena` trait
  remain selectable.
- **PERF-15.** Measure six cuts of the Storefront session: cold start, full
  session, settled actions, an inventory burst, catalog-funnel memory, and the
  same compute work without Cog. Before reporting time, each cut checks visible
  IDs, totals, async generations, invalidation, and its checksum.
  impl/benchmarks.md records the workload, environment, results, and limits.
- **PERF-16.** Run the same session in the SwiftUI app with XCUIAutomation in
  release. Measure launch, scroll, scroll under load, search, navigation, and
  cart actions on one pinned simulator. Reset state before each run. Treat
  simulator hitch data as a regression signal, not a user promise.
- **PERF-17.** The representative headless workload runs under the specialized
  default and public `CompactArena` trait, so the supported binary-size trade
  is measured on an application shape rather than only on synthetic graphs.
  impl/benchmarks.md preserves the earlier simple-core comparison alongside
  the current paired measurement.

## 19. LEG — Build-settings matrix

_Milestones M0 and M1, except LEG-04 (M4). Design: §7, §9, plan Manifest
choices._

Cog behaves the same no matter how my app is compiled.

- **LEG-01.** The whole host-runnable suite passes in all four legs:
  default MainActor isolation on and off, crossed with
  `NonisolatedNonsendingByDefault` on and off. (`CogBoundaryTests` runs
  on the simulator in its own single configuration.) (Proof: suite.)
- **LEG-02.** A leg-assertion test proves each leg really compiled with
  its intended settings, so the matrix cannot silently collapse.
- **LEG-03.** The suite also passes in the release-configuration
  `test-release` leg, where the every-build guardrails — second app
  context, escaped writer, cycles, no `CogTesting.seed`, no history cost — prove
  they hold outside debug. (Proof: release configuration.)
- **LEG-04.** The package builds with its macOS 14 deployment target, and
  the Weather example builds with an iOS 17 deployment target under Swift
  6.2 tools, with no accidental dependency on newer runtime APIs. The
  scratch-app half of the original proof was M4-04c's recorded one-time
  run; the Weather build is the leg that keeps re-proving it. (Proof:
  suite.)

## 20. ACTOR — MainActor confinement

_Milestone M1. Design: §1.2, §2.5, §7._

The graph has one execution lane regardless of my target's default isolation
settings.

- **ACTOR-01.** Selectors, turn bodies, and reactions all execute on the
  MainActor. Runtime preconditions prove it in every build-settings leg.
- **ACTOR-02.** Code on another executor tries to access the synchronous
  graph API without a MainActor hop. The compiler says no. (Proof: compile-fail.)
- **ACTOR-03.** A manual cog holds a non-`Sendable`, MainActor-bound value,
  and an automatic cog reads it without a wrapper or an unchecked conformance.

## 21. LINT — First-party lint tooling

_Milestone M8. Design: [lint.md](../design/lint.md)._

The conventions that make Cog code easy to read fail at the same source
locations in my editor and CI, without making my app compile the linter.

- **LINT-01.** I run `coglint` on an explicit mix of files and directories.
  It discovers Swift files in deterministic order, reports each violation at
  its exact line and column in Xcode's diagnostic grammar with the rule slug
  and help URL, exits nonzero for errors, and exits zero for clean input.
- **LINT-02.** Each rule fixture distinguishes triggering and non-triggering
  examples and exact diagnostic positions. The harness fails if any of those
  expectations drift, and emits the canonical DocC examples from that same
  corpus instead of maintaining a second copy.
- **LINT-03.** An exact next-line suppression written as
  `// coglint:disable-next-line <rule> -- <non-empty reason>` suppresses exactly
  that rule on exactly the following physical line; it neither leaks farther
  nor hides another rule, and a missing reason suppresses nothing.
- **LINT-04.** The declaration classifier recognizes direct constructors and
  explicit nominal annotations paired with `.init`, normalizing module
  qualification, generic arguments, and optional wrapping, and carries shape
  and writable-source kind through `.readOnly` projections.
- **LINT-05.** The declaration classifier stays silent for its documented
  syntax-only evasions: inferred factories, typealiases, the sanctioned
  debug seed-target re-export, and identity that requires cross-file
  conformance or data flow.
- **LINT-06.** `cog-declaration-suffix` requires a recognized keyless
  declaration to end in singular `Cog`, a recognized box to end in plural
  `Cogs`, and all narrower qualifiers to precede that suffix.
- **LINT-07.** `no-cogs-in-view-init` rejects written `Cogs` types in a
  recognized view's stored properties, initializer parameters, and method
  parameters, including optional and generic positions, and points to
  `@Environment(\.cogs)` as the conforming boundary.
- **LINT-08.** `primitives-only-in-ops` rejects `turn` and `refresh` on
  classified production graph receivers and rejects bare or
  `self`-qualified primitives inside `extension Cogs`, including environment,
  assembly-local, selector, reaction, and mechanism-controller spellings.
- **LINT-09.** `primitives-only-in-ops` allows bare primitives and nested
  writer work lexically inside `extension CogOps`, and explicit test-target
  configuration allows tests to drive graph primitives directly.
- **LINT-10.** `initial-state-in-mechanism` allows a local bound directly from
  `Cogs.assemble` to appear only in its retention assignment inside a
  recognized `App` initializer; named ops, reads, helpers, and primitives
  before or after retention are violations.
- **LINT-11.** `initial-state-in-mechanism` allows direct assembly retention
  and service or mechanism construction before assembly, while documenting
  factory-hidden assembly and cross-file `App` conformance as accepted
  syntax-only misses.
- **LINT-12.** `manual-cog-private` accepts `private` and `fileprivate` on
  every recognized `Cog<Value>.Manual` and `CogBox<Value, Key>.Manual` source and rejects implicit
  internal or any wider access.
- **LINT-13.** `no-multi-read-cogs-helper` rejects a value-returning member of
  `extension Cogs` or `extension CogOps` whose immediate lexical body contains
  two or more direct value, status, or peek reads.
- **LINT-14.** `no-multi-read-cogs-helper` excludes nested-closure reads,
  void members, and written `View`, `some View`, or `Binding` returns, and
  stays silent for helpers outside those extensions and repackaging that
  requires data-flow analysis.
- **LINT-15.** The GitHub reporter emits one correctly escaped workflow
  annotation per finding with the same path, line, column, severity, slug,
  message, and help URL as the Xcode reporter.
- **LINT-16.** The SARIF reporter emits schema-valid output with exact source
  regions and each rule's stable URL as `helpUri`.
- **LINT-17.** A scratch SwiftPM package and Xcode project apply the
  build-tool plugin, receive its diagnostics, and receive the same diagnostics
  again when unchanged inputs take the plugin cache path. (Proof: suite.)
- **LINT-18.** A scratch consumer invokes the command plugin and observes the
  same rule engine, target-role behavior, and reporters as the bare CLI.
  (Proof: suite.)
- **LINT-19.** The checksummed artifact bundle contains each supported macOS
  host variant, and SwiftPM selects and executes the matching executable on
  every supported host. (Proof: suite.)
- **LINT-20.** The selected Channel A or Channel B manifest keeps swift-syntax
  and argument-parser out of an ordinary Cog consumer's source dependency
  graph and satisfies the recorded unused-artifact-fetch result. (Proof: suite.)
- **LINT-21.** `mise run lint:swift` first runs the linter's own suite, then
  lints the root library, the Storefront workload package, and both example
  apps' production sources with production rules, and every tracked test
  target source with the primitive exemption; the repository is clean.
  (Proof: suite.)
- **LINT-22.** Every diagnostic's stable URL resolves inside the matching
  version of `Cog.docc`, and each article's examples match the fixture corpus.
  (Proof: suite.)
- **LINT-23.** A scratch iOS 17 consumer resolves the selected lint
  distribution at exactly 0.4.0, applies the build-tool plugin, executes the
  matching released binary, and reaches that release's rule documentation.
  (Proof: suite.)
- **LINT-24.** `manual-cog-underscore` requires every recognized
  `Cog<Value>.Manual` and `CogBox<Value, Key>.Manual` declaration name to
  begin with `_`, and requires a `.readOnly` projection of a recognized source
  to be named exactly its source's name without the leading underscore; an
  underscored source that is never projected is accepted.
