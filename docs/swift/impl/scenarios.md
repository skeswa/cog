# Cog for Swift: test scenarios

_August 9, 2026_

This is the scenario tree for building Cog test-first. Every behavior the
library promises is written here as a tiny story. "I" is always the library
user: an engineer writing an app that needs state management they can trust.
Cog is the library.

## How to use this document

- Work red-green. Pick a scenario, write it as a failing test, watch it fail,
  then write the smallest code that makes it pass. The test suite, not this
  document, records what is green.
- Scenario IDs are stable. Never renumber or reuse an ID; add new scenarios at
  the end of their group. Tests should carry their scenario ID in their name
  or a comment so the suite and this tree stay linked.
- API spellings in these stories follow the current design sketch. When core
  §10 settles a provisional spelling such as tracked `cogs.get`, update the
  story and its test call sites without changing the scenario ID; the ID names
  the behavior, not the spelling.
- Each group is tagged with the milestone from [plan.md](./plan.md) that turns
  it green, and points at the design sections it comes from. Every scenario is
  also covered by exactly one task in [tasks.md](./tasks.md); a task's
  _Greens:_ line is the coverage ledger. Section numbers
  resolve per the shared map: §6 lives in
  [effects.md](../design/effects.md), §5.4 in [rx.md](../design/rx.md), perf
  §n in [perf.md](../design/perf.md), everything else in
  [exploration.md](../design/exploration.md).
- Every scenario carries a proof mode naming the check class that greens it:
  `unit` (a host `swift test` — the default, left unmarked), `compile-fail`,
  `exit test`, `release configuration`, `simulator`, `floor runtime`,
  `suite`, and `benchmark` (the default for every scenario in group 18).
  Non-unit modes are marked with a trailing `(Proof: ….)` on the scenario.
  The task-ledger checker matches each mode against the owning task's type
  and verification commands — exit tests must be proven in debug and
  release, behavior filters must expand to exactly their unit- and
  exit-test-mode scenarios, and only suite- and release-configuration-mode
  scenarios may be greened by a gate.
- Every test obeys the three testing constraints in the next section: fully
  optimistic, as fast and cheap as possible, and as implementation agnostic
  as possible. UI tests live
  in `CogBoundaryTests`; run-count tests in `CogScenarioTests`; everything else
  in `CogTests`, run in all four build legs and once more in the
  release-configuration `test-release` leg (plan M0), which is where every-build
  guardrail claims are proven outside debug. Scenarios that exercise
  debug-only surface — `seed`, debug history content, debug warnings —
  compile out of the `test-release` leg behind `#if DEBUG`; that leg proves
  their absence instead (SEED-05, HIST-04).
- A dropped scenario's line is deleted. While no tests exist yet, its group
  is renumbered to stay gapless; once tests link to IDs, the ID retires
  instead and a gap is expected.
- Behavior blocked on a core §10 open question has no scenario yet. The
  affected group carries a _Pending_ line naming the question; add the
  scenarios at the end of that group when the decision lands.
- Scenarios in group 18 are benchmark-gated. Threshold scenarios hold
  provisional thresholds, and comparison scenarios keep representation choices
  open, until perf.md records numbers.

## Testing constraints

Three constraints govern every test this tree produces. When a scenario and a
constraint seem to collide, rewrite the test until both hold; no scenario
justifies a slow, flaky, or core-coupled test.

1. **Fully optimistic.** A test drives straight to its conclusion and never
   hedges against nondeterminism. Every suspension awaits a definite signal
   the test controls — an injected clock advancing, a continuation resuming,
   a deterministic internal acknowledgement — never a sleep, a timeout used
   as synchronization, a poll loop, a retry, or a flake allowance. Nothing in
   a test happens "eventually"; if a promised signal might not arrive, that
   is a library bug for the test to expose, not a reason to wait longer.
2. **As fast and cheap as possible.** The default home for every test is
   host-side `swift test`. Simulators appear only where the promise is about
   a device runtime, and only in `CogBoundaryTests`; the iOS 17 floor subset
   runs nightly, never per PR. Time is always injected — including
   `whileObserved` grace periods, which elapse on the testing context's
   injected clock — so no test spends wall-clock time waiting. Graphs are as
   small as the behavior allows. Compile-fail checks batch into one
   expected-failure fixture pass, and trap guarantees are Swift Testing exit
   tests, kept few because each spawns a child process.
3. **As implementation agnostic as possible.** A test observes the loosest
   surface that can prove its behavior, in this order: the public `Cog` API,
   the `CogTesting` product, the debug history surface, and only then a named
   diagnostic seam. Wherever a scenario says "internal seam," it means such a
   seam: a narrow behavior contract exposed through the testing product —
   "the last cycle diagnostic," "deinit cleanup reached the MainActor" —
   never a peek at node storage, edge layout, or any other representation.
   COUNT-09 through COUNT-11 are the enforcement: the whole behavior suite
   must pass unchanged across ref layouts and the M6 core swap, so a test
   that could notice the swap is wrong. Group 18 (PERF) is the one declared
   exception; it gates the implementation itself and lives in the benchmark
   package.

## The tree

```text
 1. ONE    One app, one graph
 2. DECL   Declaring state
 3. READ   Reading state
 4. TURN   Writing state and turns
 5. GRAPH  Derived values stay right and lazy
 6. CYCLE  Cycles and mistakes
 7. REACT  Reactions
 8. GROUP  Effect groups and timers
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
```

---

## 1. ONE — One app, one graph

_Milestone M1. Design: §2.3, §6.3, §6.6._

My whole app shares one Cog world. Tests get their own little worlds.

- **ONE-01.** App bootstrap installs the one Cog context at launch. An op
  declared in one feature file commits a write, and a read made elsewhere
  through the installed context sees it — no other setup, no second
  context anywhere.
- **ONE-02.** Some code tries to install a second app context. Cog stops
  it right away with a clear error, in debug builds and release builds.
  (Proof: exit test.)
- **ONE-03.** Feature code tries to build a plain `Cogtext` with an
  initializer. The compiler says no. (Proof: compile-fail.)
- **ONE-04.** My test asks the testing product for a context. It gets a
  fresh, isolated one that works without any app setup.
- **ONE-05.** Tests and previews each make their own context — two at
  once, then many more, one after another. Each context starts clean, a
  write in one is invisible to every other, and none of them trips the
  app-install guard.
- **ONE-06.** SwiftUI throws my views away and rebuilds them (a scene is
  recreated). My manual state is still there, because it lives in the app
  context, not in the views.

## 2. DECL — Declaring state

_Milestone M1. Design: §2.3, §3.1, §4._

I declare state at the top of a file and it just works.

### 2.1 Sources

- **DECL-01.** I declare a `ManualCog` with a starting value. When I read
  it, I get that starting value.
- **DECL-02.** I declare a `ManualCogBox` with a starting value. Each key
  I look up starts at that value, and each key holds its own value.
- **DECL-03.** I give a box a starting-value closure instead. Each key
  starts at what the closure returns for that key.
- **DECL-04.** I build `box[5]` in two different places. Both refs point
  at the same state: writing through one shows up when reading the other,
  and `box[6]` does not change.
- **DECL-05.** I expose a source through `.readOnly`. Reading the
  read-only ref always gives the same value as the source.
- **DECL-06.** I try to write through a `.readOnly` ref. The compiler says
  no. (Proof: compile-fail.)

### 2.2 Derived cogs

- **DECL-07.** I declare a `Cog` that computes from other cogs. Reading it
  gives the computed value.
- **DECL-08.** I declare a derived `CogBox`. The closure receives the key
  as a parameter and passes it to inner keyed reads by normal lexical
  capture, and each key computes with its own key.
- **DECL-09.** Declaring cogs runs nothing. A derived cog's closure runs
  for the first time only when someone first reads it.

### 2.3 Names

- **DECL-10.** I declare a cog with a `name:`. That name appears when Cog
  talks about the cog (diagnostics and debug history).
- **DECL-11.** I declare a cog without a name. Cog falls back to the file
  and line where I declared it.

### 2.4 Selector shape

- **DECL-12.** I declare a derived cog whose selector throws. The
  compiler says no: synchronous selectors do not throw in v1. (Proof: compile-fail.)

## 3. READ — Reading state

_Milestone M1. Design: §2.2, §2.4._

Every read I make is correct: the latest committed state, fully settled.

- **READ-01.** I write a source in a commit. After the commit, every read
  sees the new value.
- **READ-02.** I read a derived cog twice with nothing changing in
  between. Its closure ran only once; the second read used the cache.
- **READ-03.** I change two sources in one commit. A derived cog that
  combines them sees both new values together, never one new and one old.
- **READ-04.** A selector uses `c.curr` to see its own previous value and
  keeps a running total. Each turn folds the new input into the total.
- **READ-05.** The very first run of a `c.curr` selector has no previous
  value, and the selector can tell.
- **READ-06.** A selector tracks a trigger and peeks at cog X with
  `c.read`. Changing X alone does not rerun the selector. When the trigger
  later changes, the selector reruns and the peek returns X's newest
  settled value.
- **READ-07.** I leave a derived cog cold while its source changes, then
  use one-shot `cogs.read`. It settles the derived cog and returns its
  newest value without creating a subscription.

## 4. TURN — Writing state and turns

_Milestone M1. Design: §3.2, §2.2._

`commit` is the only door for writes, and every commit is one named turn.

### 4.1 The writer

- **TURN-01.** Inside one commit, `w[count] += 1` works: the writer reads
  back the value it just staged.
- **TURN-02.** I write the same source twice in one commit. The last
  write wins, and downstream sees exactly one change.
- **TURN-03.** The writer reads a source I have not written this turn. It
  sees the current committed value.
- **TURN-04.** While a commit body is still running, a normal read (not
  through the writer) still sees the old values. Staged values are
  visible only to the writer.

### 4.2 Turns join, queue, and end

- **TURN-05.** A commit inside a commit joins the outer turn. Everything
  flushes once, when the outer body ends, and reactions run once.
- **TURN-06.** A turn takes its name from the op method that made it, or
  from a custom name I pass. That name is what history shows.
- **TURN-07.** I sneak the writer out of the commit — stashed in a
  variable or captured into an async task — and use it after the commit
  ended. Cog stops me with an error, in every kind of build. (Proof: exit
  test.)
- **TURN-08.** Several commits queue up during a flush. They run one at a
  time in the order they arrived, and each queued turn finishes
  completely — settle, notify, react — before the next one starts.

### 4.3 Equal writes are not changes

- **TURN-09.** I write a source to the value it already has. Nothing
  happens: no recompute, no notice, no reaction.
- **TURN-10.** In one commit I change a value and then change it back.
  At flush time that counts as no change at all.
- **TURN-11.** I give a cog a custom `equals:`. Cog uses my rule to
  decide whether a new value counts as a change.
- **TURN-12.** A cog holds a value with no `Equatable`. Cog plays it safe
  and treats every write as a change.
- **TURN-13.** I run two sibling commits back to back in one event
  handler. Each is its own named turn: two history entries, and reactions
  run after each one.
- **TURN-14.** Inside one commit, `w[box[k]] += 1` works: the writer
  reads back the value staged for that key, and other keys are untouched.

## 5. GRAPH — Derived values stay right and lazy

_Milestone M1. Design: §2.2, §2.4, §5.4._

Cog recomputes only what is needed, only when it is needed, and never shows a
half-finished picture.

### 5.1 Shapes

- **GRAPH-01.** A chain: A feeds B feeds C. I change A and read C. C is
  right.
- **GRAPH-02.** A diamond: A feeds B and C, which both feed D. I change A
  once. D recomputes once, using B and C from the same turn.
- **GRAPH-03.** A chain deep enough to overflow a recursive walk settles
  correctly from top to bottom without exhausting the stack.
- **GRAPH-04.** One source feeds many derived cogs. Each one I read is
  right, and only the ones I read recompute.

### 5.2 Equal values stop the wave

- **GRAPH-05.** A middle cog recomputes but lands on the same value as
  before. The cogs below it do not recompute.
- **GRAPH-06.** A middle cog changes every time. The cogs below it keep
  following it.

### 5.3 Laziness

- **GRAPH-07.** Nobody is watching a derived cog. I change its source.
  Its closure does not run. When I later read it, it runs then.
- **GRAPH-08.** A cold cog misses ten turns of changes. When I finally
  read it, it computes once, from the newest values — not once per
  missed turn.

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

_Milestone M1. Design: §2.4, perf §3.4._

If I accidentally make state depend on itself, Cog tells me exactly where.

_Pending (core §10, open question 11): the failure mode for a selector that
calls an op which commits mid-computation._

- **CYCLE-01.** A cog reads itself. Cog fails and names the cog. (Proof:
  exit test.)
- **CYCLE-02.** Cog A reads cog B, and B reads A. Cog fails and shows the
  whole path, A to B and back. (Proof: exit test.)
- **CYCLE-03.** The cycle runs through keyed cogs. The message includes
  the keys, so I can see which items looped.
- **CYCLE-04.** A cycle only exists when a condition is true. Everything
  works until the condition flips; then Cog catches it.
- **CYCLE-05.** My test can look at the cycle diagnostic through an
  internal seam without crashing the test process.

## 7. REACT — Reactions

_Milestone M1, except REACT-19 (M2) and REACT-20 (M7). Design: §3.3, §6.2,
§6.4._

A reaction watches state and does something outside the graph when it
changes.

_Pending (core §10, open question 16): when a reaction registered during a
flush — from inside another reaction — makes its initial run._

### 7.1 Running

- **REACT-01.** I register a reaction with `cogs.run`. It runs once right
  away, so Cog learns what it reads.
- **REACT-02.** A turn changes something my reaction reads. The reaction
  runs again.
- **REACT-03.** A turn changes something my reaction does not read. The
  reaction stays quiet.
- **REACT-04.** When a reaction runs, everything it reads is already
  settled from the turn that woke it.
- **REACT-05.** I register three reactions. When a turn wakes all three,
  they run in the order I registered them.
- **REACT-06.** A reaction's reads change from run to run, like a
  selector's. It is re-tracked every run.
- **REACT-07.** Reactions run before the op that committed the turn
  returns. The very next line of my test can check what the reaction did.
- **REACT-08.** `watch(_, initial: .skip)` does not call me at install
  time; the first real change calls me with the old and new values.
- **REACT-09.** `watch(_, initial: .run)` calls me once at install time.

### 7.2 Tokens

- **REACT-10.** I cancel a reaction token. The reaction never runs again.
- **REACT-11.** I cancel the same token twice. Nothing bad happens.
- **REACT-12.** I drop the last copy of a token. The reaction is
  cancelled by deinit.
- **REACT-13.** I copy a token. Both copies mean the same registration;
  cancelling either one stops the reaction.

### 7.3 Writing back

- **REACT-14.** A reaction gets a read-only view of the graph. It cannot
  write directly. (Proof: compile-fail.)
- **REACT-15.** A reaction calls an op that commits. That write becomes a
  brand-new turn after the current flush — never a change to the turn
  being flushed.
- **REACT-16.** Reaction A's write wakes reaction B, whose write wakes C.
  The turns run one at a time, first-in first-out, and each sees settled
  state.
- **REACT-17.** Two reactions deliberately wake each other for 65 turns
  and then stop. In debug, Cog warns after about 64 uninterrupted turns,
  exposing the warning and its causal chain of turns and reactions through
  the diagnostic seam, and the context is idle again before the op that
  started the chain returns — asserted directly, never awaited.
- **REACT-18.** The last copy of a reaction token is dropped on a
  background executor. I await an internal acknowledgement that deinit
  cleanup reached the MainActor, then commit a dependency change. The
  reaction does not run; immediate stopping still requires explicit
  `cancel()`.
- **REACT-19.** Within one flush, every changed UI boundary is notified
  before any reaction runs — flush step 4 before step 5. (Checked through
  history or an internal seam once M2 boundaries exist.)
- **REACT-20.** Within one flush, every changed export value is offered to
  its subscriber buffers before any reaction runs — flush step 4 before
  step 5. (Checked through history or an internal seam once M7 exports
  exist.)
- **REACT-21.** A reaction watches a derived cog. A turn changes that
  cog's source, but the recompute lands on an equal value. The reaction
  does not run: only changed reactions run in flush step 5.

## 8. GROUP — Effect groups and timers

_Milestone M1. Design: §6.2, §6.3._

An `EffectGroup` owns the lifetime of my app's effects.

_Pending (core §10, open question 12): whether adding a token to an
already-cancelled group cancels it immediately or traps._

- **GROUP-01.** I add a watch token to a group. Cancelling the group
  stops the watch.
- **GROUP-02.** I start a task with `group.task`. Cancelling the group
  cancels the task.
- **GROUP-03.** I cancel a group twice. Nothing bad happens.
- **GROUP-04.** I drop the last copy of a group. Everything it owned is
  cancelled.
- **GROUP-05.** I copy a group. Both copies own the same effects;
  cancelling either stops them all.
- **GROUP-06.** A group task sleeps on an injected clock and then calls
  an op every hour. When my test clock jumps an hour, the op runs and its
  named turn lands in debug history. Before that, it does not run.
- **GROUP-07.** A screen installs its own group and later cancels it. The
  screen's effects stop, but the app's state is untouched.
- **GROUP-08.** Declaring an effects struct does nothing by itself.
  Effects exist only after I call `install(in:)`.
- **GROUP-09.** The last copy of a group is dropped on a background
  executor. I await an internal acknowledgement that deinit cleanup reached
  the MainActor, then verify its reaction registrations are gone and every
  owned task has received cancellation. Immediate stopping still requires
  explicit `cancel()`.

## 9. LIFE — How long state lives

_Milestone M1 (UI pinning lands with M2; async release with M3). Design: §5.3,
perf §7._

State lives as long as its kind says, and coming back is always safe. Grace
periods elapse on the testing context's injected clock; no lifetime test
waits wall-clock time.

- **LIFE-01.** Nobody watches a manual cog for a long time. Its value
  survives anyway, because manual state defaults to app lifetime.
- **LIFE-02.** A derived cog defaults to `whileObserved`. After its last
  watcher leaves and the grace period passes, Cog lets it go. The next
  read simply computes it fresh.
- **LIFE-03.** A released derived cog is read again through the same ref.
  It comes back with the correct current value, as if it never left.
- **LIFE-04.** A watcher leaves and comes back within the grace period.
  The cog was never released and did not recompute.
- **LIFE-05.** A manual cog opts into
  `whileObserved(resetToInitial: true)`. After release, the next read
  gives the starting value again.
- **LIFE-06.** I mark a derived cog `keepAlive`. It survives with no
  watchers, exactly like app lifetime.
- **LIFE-07.** A registered reaction counts as a watcher: the cogs it
  reads stay alive.
- **LIFE-08.** Once a view has read a cog, that cog is pinned for the
  life of the app context. It is never released behind SwiftUI's back.
- **LIFE-09.** Derived cog B reads derived cog A, then both lose their last
  external consumer. Their internal graph edge does not keep them alive.
  After the grace period, reading either ref recreates the needed nodes
  with the correct current values.

## 10. SEED — Test helpers: seed and stub

_Milestone M1, except SEED-07 (M2). Design: §6.6, §4._

My tests set up state quietly with `seed`, or loudly with a real commit.

- **SEED-01.** I seed a source. The next read returns the seeded value.
- **SEED-02.** Seeding is quiet in the M1 runtime: no turn lands in history
  and no reaction runs.
- **SEED-03.** Seeding still marks dependents dirty: a derived cog read
  after the seed recomputes from the seeded value.
- **SEED-04.** The §6.6 alert story, verbatim: install a nice-weather
  alert reaction, seed the zip and cloudy weather (no alert), then stub
  sunny weather with a real commit. The alert fires exactly once, even
  though the reaction's first run never read the weather.
- **SEED-05.** `seed` exists only in debug builds. A release build has no
  way to seed. (Proof: release configuration.)
- **SEED-06.** I try to seed a derived cog. The compiler says no: only
  manual sources can be seeded. (Proof: compile-fail.)
- **SEED-07.** Once M2 UI boundaries exist, I seed a source that a view has
  read. Seeding sends no UI notice; the next real turn still settles and
  notices the value dirtied by the seed.

## 11. HIST — Debug history

_Milestone M1, except HIST-06 (M2). Design: §2.3, §6.2, perf §8._

When I wonder what happened, the debug history can tell me.

- **HIST-01.** Every turn lands in history with its name.
- **HIST-02.** History records writes and recomputations.
- **HIST-03.** History is bounded: after many turns, the oldest entries
  fall off and the entry count never passes the cap. (Memory itself is
  benchmark territory, not a unit-test assertion.)
- **HIST-04.** Release builds pay nothing for history. (Proof: release configuration.)
- **HIST-05.** A watch registered with a `name:` runs. Its run lands in
  history under that effect name.
- **HIST-06.** Once M2 boundaries exist, history records each changed UI
  notice with the cog's human-readable label.

## 12. UI — SwiftUI and UIKit boundary

_Milestone M2, in `CogBoundaryTests` and the Weather example. Design: §3.4,
§7, §9, perf §6._

My views update when — and only when — the values they read change. Boundary
tests assert Observation notices and re-render counters, never pixels or
wall-clock waits; real rendering is proven once by the Weather example.

- **UI-01.** A view reads a cog with `cogs.get`. When that cog changes,
  the view re-renders.
- **UI-02.** When a cog the view never read changes, the view does not
  re-render.
- **UI-03.** A card reads `weather[zipA]`. Writing `weather[zipB]`
  re-renders only zipB's card, never zipA's.
- **UI-04.** A derived cog recomputes but lands on an equal value. Views
  reading it do not re-render.
- **UI-05.** Only cogs that a view actually read get an Observation
  boundary object. Interior graph nodes never do. (Checked through an
  internal seam.)
- **UI-06.** Views find the one app context through the `\.cogs`
  environment key.
- **UI-07.** `binding(for:)` shows the current value, and setting it
  writes through a named commit that shows up in history.
- **UI-08.** A text field writes through a binding and immediately reads
  back. It sees its own write — no dropped characters.
- **UI-09.** A view uses one-shot `cogs.read` in its body. Later changes
  to that cog do not re-render the view.
- **UI-10.** In debug, reading with tracked `get` from a place with no
  consumer — like a `Button` action — surfaces a warning through the
  diagnostic seam that points at the mistake.
- **UI-11.** UIKit automatic tracking works through the same boundary on
  an iOS 26 simulator. (Proof: simulator.)
- **UI-12.** AppKit automatic tracking works through the same boundary on
  a macOS 26 host.
- **UI-13.** A view reads two cogs, A and B. One commit changes both. Every
  render sees either the old pair before the commit or the new pair after
  it — never one old value and one new value.
- **UI-14.** On an iOS 17 simulator, the tracked-read, unrelated-write,
  equality-gated notice, and immediate binding scenarios (UI-01, UI-02,
  UI-04, and UI-08) have the same behavior through the floor-runtime
  Observation boundary. This may run in the pinned nightly floor job.
  (Proof: floor runtime.)

## 13. ASYNC — Async values, first slice

_Milestone M3. Design: §5.1, §5.2 (`.latest` only), §5.3._

Async state is honest: it always says whether it is loading, what it has, and
what it had.

_Pending (core §10, open question 15): what a one-shot `cogs.read` of a
never-read async cog does — does it create the node, start work, and publish
a pending turn? — and what `cogs.refresh` of a never-read ref does._

### 13.1 Phases

- **ASYNC-01.** I read an `AsyncCog` for the first time. It starts its
  work, publishes a pending turn, and returns
  `.pending(previous: .none)`. There is no observable `initial` phase.
- **ASYNC-02.** The work throws. The phase becomes failure holding the
  error — and the previous value, if there was one.
- **ASYNC-03.** An async cog whose value is optional succeeded with
  `nil`. When it reloads, its previous value is "some(nil)" — clearly
  different from "never had a value."
- **ASYNC-04.** `latestValue` and `isLoading` are right in every phase:
  nothing and loading at first; the old value and loading while
  reloading; the value and not loading on success; the last good value
  and not loading on failure.
- **ASYNC-05.** The `.latest` projection lets me read an async cog as a
  plain optional value, the same shape as a manual cog.
- **ASYNC-06.** A watcher sees each visible phase change as its own turn:
  first pending, then success, two separate turns.

### 13.2 Latest wins

- **ASYNC-07.** A dependency changes while work is in flight. The old
  work is cancelled and new work starts — whether the policy was spelled
  `.latest` or omitted, since `.latest` is the default.
- **ASYNC-08.** The old work finishes anyway, ignoring cancellation. Its
  result is thrown away. Only the newest run may commit.
- **ASYNC-09.** Work that was cancelled because it was replaced publishes
  no failure phase.
- **ASYNC-10.** I call `cogs.refresh(ref)`. The work runs again even
  though no dependency changed, and the phases cycle again.
- **ASYNC-11.** Only what the selector reads with `c.get` before
  returning counts as a dependency. Values the work closure touches after
  an `await` do not retrigger it.
- **ASYNC-12.** Two keys of an `AsyncCogBox` fetch independently. One can
  be loading while the other has succeeded.

### 13.3 Safe release

- **ASYNC-13.** An unwatched async cog is released while its work is
  pending. The work is cancelled, and if a late result sneaks through, it
  commits nothing.
- **ASYNC-14.** After a release, reading the ref again starts fresh work
  and fresh phases, unpolluted by anything from before.

### 13.4 Work isolation and previous values

- **ASYNC-15.** An async cog's work body runs on the MainActor by
  default. A runtime precondition inside the work proves it in every leg.
- **ASYNC-16.** Expensive work opts into `@concurrent`. It runs off the
  main actor, and its result still commits on the MainActor under the
  same generation check.
- **ASYNC-17.** The internal task that runs an async cog's work carries
  the descriptor's name and key, so Instruments can show it. (Checked
  through an internal seam.)
- **ASYNC-18.** Initial work throws. A watcher and history see pending with
  no previous value, then failure with no previous value, as two distinct
  turns.
- **ASYNC-19.** Work succeeds, then a dependency change starts a reload
  that fails. A watcher and history see success, pending with that success
  as the previous value, then failure with the same previous value, each as
  its own turn. A further reload's pending still carries that success —
  the last good value, never the failure.
- **ASYNC-20.** A reload succeeds with a value equal to the one it had.
  Watchers of the full phase see the pending and success turns, but
  consumers of the `.latest` projection see no change: no recompute, no
  re-render.
- **ASYNC-21.** I call `cogs.refresh(ref)` while work is already in
  flight. Under `.latest`, the in-flight run is cancelled and only the
  newest run may commit — a refresh replaces work the same way a
  dependency change does.

## 14. POLICY — Ordered async policies

_Milestone M7. Design: §5.2, §5.4._

When order matters more than speed, I pick a policy that says so.

_Pending (core §10, open question 10): whether a failed `.queue` run stops
the queue or the next queued run still starts._

- **POLICY-01.** After the initial run succeeds, three quick dependency
  changes under `.queue` make exactly three additional runs, one at a time
  and in input order. Each run starts only after the preceding one
  finishes.
- **POLICY-02.** With `.queue`, results commit in run order, so the final
  value always matches the newest input.
- **POLICY-03.** With `.exhaustLatest`, changes during a run — one or
  ten — start no new runs. When the run finishes, exactly one catch-up
  run uses the newest state.
- **POLICY-04.** With `.merged`, runs overlap, and each result commits as
  its own turn when it lands.
- **POLICY-05.** A `.stream` selector cannot use `.queue`,
  `.exhaustLatest`, or `.merged`. The type system says no. (Proof: compile-fail.)

## 15. STREAM — Streams

_Milestone M7. Design: §5.1, §5.2, §5.4._

Some state really is a stream — locations, sockets, database watches.

_Pending (core §10, open questions 8, 9, and 14): what phase a stream
publishes when its sequence ends naturally, whether a throwing sequence
publishes a failure, and whether consecutive equal elements each commit a
turn or are equality-gated (STREAM-01 versus the TURN-09 rule)._

- **STREAM-01.** A `.stream` cog commits each element of its sequence as
  its own turn. Watchers see every committed value.
- **STREAM-02.** Before the first element arrives, the cog reports
  loading.
- **STREAM-03.** A dependency changes. The old sequence is cancelled and
  a new one starts; late elements from the old sequence commit nothing.
- **STREAM-04.** An unwatched `.stream` cog is released while its
  sequence is live. The sequence is cancelled, and late elements commit
  nothing.

## 16. EXPORT — Exports and interop

_Milestone M7. Design: §8, §6.5._

Cog state can flow out as an `AsyncSequence`, and outside state can flow in.

- **EXPORT-01.** I subscribe with `cogs.values(of:)`. The first thing I
  get is the current settled value — even for a cold cog nobody has read
  before; subscribing settles it.
- **EXPORT-02.** After that, I get a value each time it changes.
- **EXPORT-03.** After consuming the initial value, I pause a default
  `.newest(1)` reader and commit A, B, then C. Its next value is settled C;
  A and B may be skipped, and none of the commits waits for the reader.
- **EXPORT-04.** After consuming the initial value, I pause an `.oldest(2)`
  reader and commit A, B, then C. It receives settled A and B in order and
  drops C; none of the commits waits for the reader.
- **EXPORT-05.** Two subscribers to the same cog own independent buffers
  and graph leases. Pausing or cancelling one neither drops values from nor
  releases the lease of the other.
- **EXPORT-06.** Cancelling the reading task releases that subscriber's
  graph lease, so a `whileObserved` cog can be let go.
- **EXPORT-07.** A view's `.task` loops over `values(of:)`. When the view
  disappears, the loop ends and the lease is gone — the §6.5 map-camera
  story. (Proof: simulator.)
- **EXPORT-08.** I link an outside `@Observable` property in with
  `c.track`. After an observed mutation finishes propagating, my dependent
  cog returns the newest post-mutation value — never the pre-write value.
  Repeating this after each propagation boundary keeps returning the newest
  value; mutations within one boundary may coalesce. (Proof: simulator.)
- **EXPORT-09.** After consuming the initial value, I pause an `.unbounded`
  reader and commit A, B, then C. It receives every settled value in order.
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
  synchronous mutations may coalesce until the next observation suspension
  boundary, where the newest value propagates. (Proof: simulator.)
- **EXPORT-13.** I link outside state in with `c.track`'s closure form
  instead of a key path. It has the same post-mutation value, coalescing,
  and pre-iOS-26 re-arm semantics as the key-path form. (Proof: simulator.)
- **EXPORT-14.** I subscribe to a derived cog. A turn recomputes it to an
  equal value. Nothing is offered to my buffer: only changed values reach
  subscribers.
- **EXPORT-15.** A `whileObserved` derived cog's only consumer is my
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
- **COUNT-09.** Every behavior scenario implemented through M5 passes
  unchanged over every ref layout under test. (Proof: suite.)
- **COUNT-10.** Every behavior scenario implemented through M6 passes
  unchanged with the data-oriented core selected in place of the simple
  core, before any default switch. (Proof: suite.)
- **COUNT-11.** After M7, the complete behavior suite passes unchanged on
  the selected ref layout and data-oriented core. (Proof: suite.)

## 18. PERF — Performance guarantees

_Milestones M5 and M6, in the benchmark package. Design: perf §5–§9._

Benchmark-gated: thresholds stay provisional and representation choices stay
open until perf.md records numbers. This group is the declared exception to
implementation agnosticism: it gates the implementation itself, lives in the
benchmark package, and never constrains the behavior suite. Every scenario
in this group has proof mode `benchmark` by default; no per-scenario marker
is needed.

- **PERF-01.** A steady turn — same graph shape, new values — allocates
  nothing (`mallocCountTotal == 0`).
- **PERF-02.** Propagation does no retain or release traffic.
- **PERF-03.** Peak memory for a 1,000-node graph stays within the
  baseline threshold recorded in perf.md. While no baseline exists, this
  check is red, never skipped.
- **PERF-04.** A graph with 1,000 nodes and 12 UI-read values owns 12
  boundary objects, not 1,000.
- **PERF-05.** A released node's slot is reused safely: its generation
  changes, and stale internal access is caught in debug builds.
- **PERF-06.** Building a ref with `box[key]` allocates nothing.
- **PERF-07.** Notice traffic for pinned keyed nodes — old keys the UI
  once read but no longer shows — stays within the baseline recorded in
  perf.md. While no baseline exists, this check is red, never skipped.
- **PERF-08.** Keyed diamonds and key churn run under inline `AnyHashable`,
  interned-token, and generic-keyed ref layouts in one pinned environment.
  Results land in perf.md before the ref layout is selected.
- **PERF-09.** Mostly static and high-churn graphs run under the shared
  edge pool, per-node prefix arrays, and inline-plus-overflow edge layouts
  in one pinned environment. Results land in perf.md before the edge layout
  is selected.
- **PERF-10.** The selected core is measured against the simple core,
  swift-state-graph, and raw `@Observable` in one pinned environment.
  perf.md records wall-clock results and generous absolute regression
  thresholds before timing gates enter CI.

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
  context, escaped writer, cycles, no `seed`, no history cost — prove
  they hold outside debug. (Proof: release configuration.)
- **LEG-04.** The package builds with its macOS 14 deployment target, and
  a scratch app plus the Weather example build with an iOS 17 deployment
  target under Swift 6.2 tools, with no accidental dependency on newer
  runtime APIs. (Proof: suite.)

## 20. ACTOR — MainActor confinement

_Milestone M1. Design: §1.2, §2.5, §7._

The graph has one execution lane regardless of my target's default isolation
settings.

- **ACTOR-01.** Selectors, commit bodies, and reactions all execute on the
  MainActor. Runtime preconditions prove it in every build-settings leg.
- **ACTOR-02.** Code on another executor tries to access the synchronous
  graph API without a MainActor hop. The compiler says no. (Proof: compile-fail.)
- **ACTOR-03.** A manual cog holds a non-`Sendable`, MainActor-bound value,
  and a derived cog reads it without a wrapper or an unchecked conformance.
