# Cog for Swift: task breakdown

_August 10, 2026_

This document decomposes the milestones of [plan.md](./plan.md) into
dependency-aware execution tasks of half an engineering day or less, and
assigns every scenario in [scenarios.md](./scenarios.md) to exactly one task.

## Execution rules

- **Plan and tasks are one execution contract.** [plan.md](./plan.md) owns
  milestone scope, exit criteria, and release boundaries; this ledger owns
  executable slices, dependencies, commands, and scenario ownership. Use the
  plan's milestone-to-task table for closure paths. Any change that crosses
  those ownership boundaries updates both documents in the same change.
  Live execution bookkeeping — claiming, status, discussion, and closure
  evidence — happens in the GitHub issue mirror under the plan's "Task
  bookkeeping" section; a task change here updates that mirror in the same
  change.
- **Half a day is the cap.** The estimate includes writing the red tests,
  implementation, local verification, and the task's required documentation.
  Known multi-mechanism work is split here rather than deferred until it
  overruns. If an unknown still makes a task too large, replace it in place
  with letter-suffixed tasks (`M1-07a`, `M1-07b`). Splitting an already
  suffixed task appends another letter (`M1-07aa`, `M1-07ab`). The parent ID
  is then retired as an execution unit and is never reused.
- **Task IDs are stable.** Never renumber or reuse an ID. New independent
  tasks go at the end of their milestone; splits inherit the parent's number.
- **Every task has one type.** A _Decision_ ends in a recorded choice and the
  scenarios and tasks that choice requires. _Infrastructure_ unblocks later
  behavior but greens no scenario. _Behavior_ starts with red scenario tests
  and ends with every clause green. A _Gate_ proves a slice or milestone and
  never owns the repairs it discovers. A _Release_ performs one externally
  visible publication step.
- **Dependencies are normative and minimal.** `_Depends:_` names only the
  immediate prerequisites; omit a prerequisite already implied by another
  listed dependency. A prior milestone is not a global barrier unless its gate
  is named. Tasks may run in parallel when the graph allows, but ready tasks
  that edit the same primary files must integrate serially. List order is only
  a readable topological default.
- **Milestone gates cover every behavior by dependency.** The sole exception
  is a task with an explicit `_Non-blocking:_` external-availability policy;
  it remains in the ledger but cannot hold a release hostage to unavailable
  hosted infrastructure.
- **Verification is part of the task.** `_Verify:_` names the exact command or
  review artifact that closes the task. Scenario test names contain their IDs,
  using Swift 6.2 raw test identifiers that begin with the hyphenated ID, so
  `mise run test --filter 'A|B'` selects the named slice. All filtered runs go
  through a mise wrapper that lists tests first and fails when the regular
  expression matches none; raw `swift test --filter` is forbidden because
  SwiftPM exits successfully for an empty selection. Compile-fail fixtures use
  `mise run test:compilefail`; milestone gates use the mise commands from
  [plan.md](./plan.md). Filter expressions are checked, never trusted: for a
  behavior task, the scenario filters in `_Verify:_` must expand — against
  the scenario set in [scenarios.md](./scenarios.md) — to exactly the task's
  unit- and exit-test-mode `_Greens:_` entries; exit-test scenarios appear in
  both a `test` and a `test:release` filter; compile-fail scenarios require
  `mise run test:compilefail`; and simulator, floor, benchmark, and suite
  scenarios name their runs explicitly. The checker enforces these
  expansions, so a filter can never silently drift from its coverage claim
  when a decision task adds scenarios.
- **_Greens:_ is the coverage ledger.** It means every clause of those
  scenarios is observable and passing, never merely implemented in part or
  vacuously true because a consumer does not exist yet. Every scenario ID in
  [scenarios.md](./scenarios.md) appears in exactly one `_Greens:_` line; the
  checker derives that census from scenarios.md itself, so no count is
  maintained by hand. A scenario's proof mode also constrains its owner:
  only suite- and release-configuration-mode scenarios may be greened by a
  gate; every other mode belongs to a behavior task. Infrastructure and
  decisions have no such line.
- **No task ends red.** Benchmark-gated scenarios record the measurement or
  provisional threshold they need in `perf.md` within the same task that first
  turns them green. Later baseline automation does not stand in for that
  result. If a gate exposes a defect, add or split out the smallest repair
  task, make the failed gate depend on it, and rerun the gate; do not turn the
  gate into an unbounded debugging task.
- **Releases separate preparation from publication.** A non-mutating release
  candidate gate precedes the tag; tag creation, deployment verification, and
  GitHub Release creation are separate tasks. Publications are also totally
  ordered: every _Release_ task depends, directly or transitively, on the
  previous release's terminal task — including a conditional release's
  recorded not-applicable closure — so no two release sequences can
  interleave, and every _Release_ task sits downstream of a _Gate_. A patch
  release inserts a new candidate → tag → verification → GitHub Release link
  into the same chain, reusing the M4 template.

## M0 tasks

_Plan scope and exit: [M0: Scaffolding](./plan.md#plan-m0)._

- **M0-01** _(Infrastructure)_ — Root `Package.swift` (tools 6.2, platforms,
  library settings) with stub `Cog` and `CogTesting` targets and test targets;
  add `LICENSE` and one stub test for runner verification.
  _Verify: `swift test`._
- **M0-02** _(Infrastructure)_ — Create the trimmed two-space
  `.swift-format`; split mise formatting into `fmt:md` and `fmt:swift` under
  the `fmt` and `fmt:check` umbrellas.
  _Depends: M0-01._
  _Verify: `mise run fmt:check`._
- **M0-03** _(Infrastructure)_ — Add mise `test`, `test:matrix`, and
  `test:release` commands with isolated build paths per leg. When passed
  `--filter`, each command first checks `swift test list` and fails if the
  regular expression selects no test.
  _Depends: M0-01._
  _Verify: `mise run test`, `mise run test:release`,
  `mise run test --filter M0Sentinel`, and
  `! mise run test --filter DOES-NOT-EXIST`._
- **M0-04** _(Behavior)_ — Select test isolation and NNBD legs from
  `COG_TEST_ISOLATION` and `COG_TEST_NNBD`, mirror them into `.define()`s,
  verify manifest re-evaluation, and add the leg-assertion test.
  _Depends: M0-03._
  _Verify: `mise run test:matrix --filter LEG-02`._
  _Greens: LEG-02._
- **M0-07** _(Infrastructure)_ — Add the compile-fail fixtures directory,
  batched expected-diagnostic runner, and `test:compilefail` mise command.
  _Depends: M0-01._
  _Verify: `mise run test:compilefail` against one sentinel fixture._
- **M0-05a** _(Decision)_ — Verify the `macos-26` image and pinned Xcode 26.x
  against `actions/runner-images`; record the exact runner/Xcode pair and
  selection command in the README before the workflow is created.
  _Verify: recorded runner-image source and selected version._
- **M0-05b** _(Infrastructure)_ — Create `swift-ci.yml` with
  concurrency-cancel; path filters for `Package.swift`, `Package.resolved`,
  `swift/**`, `.swift-format`, `mise.toml`, and the workflow itself; format;
  the runner/Xcode pair selected by M0-05a; and four cached host-test legs.
  _Depends: M0-02, M0-04, M0-05a._
  _Verify: a pull-request run completes all format and host-test jobs._
- **M0-05c** _(Infrastructure)_ — Add release-configuration and batched
  compile-fail jobs to `swift-ci.yml`.
  _Depends: M0-05b, M0-07._
  _Verify: a pull-request run completes both jobs._
- **M0-06** _(Infrastructure)_ — Add `markdown.yml` with path filtering and
  Oxfmt checking on Ubuntu.
  _Verify: the workflow passes for a Markdown-only pull request._
- **M0-08** _(Infrastructure)_ — Document all M0 commands in the root and
  Swift READMEs and in synchronized `AGENTS.md` and `CLAUDE.md`.
  _Depends: M0-02, M0-03, M0-07, M0-09ab._
  _Verify: `diff -u <(tail -n +8 AGENTS.md) <(tail -n +8 CLAUDE.md)` and
  `mise run fmt:check`._
- **M0-09aa** _(Infrastructure)_ — Add the task-ledger parser with recursive
  split-ID support, unique and prefix-free executable task IDs, existing
  dependencies, transitively minimal dependency lists, and acyclic-graph
  checks. Prefix-free means a retired split parent cannot reappear beside one
  of its descendants.
  _Verify: focused duplicate-ID, parent/child coexistence,
  unknown-dependency, redundant-edge, and cycle fixtures for
  `tools/check-task-ledger.mjs`._
- **M0-09ab** _(Infrastructure)_ — Add exact scenario ownership, milestone
  gate reachability, and `_Non-blocking:_` policy checks; expose the combined
  checker as `mise run tasks:check`.
  _Depends: M0-09aa._
  _Verify: `mise run tasks:check` plus missing, duplicate-owner, unreachable,
  and allowed-non-blocking fixtures._
- **M0-09ac** _(Infrastructure)_ — Validate the plan-to-task contract: exactly
  one M0–M7 map row, the matching task-section link, only existing
  same-milestone task IDs, and every explicit `_Non-blocking:_` task named in
  its row.
  _Depends: M0-09ab._
  _Verify: `mise run tasks:check` plus missing-row, wrong-link, unknown-ID,
  cross-milestone-ID, and missing-non-blocking fixtures._
- **M0-09b** _(Infrastructure)_ — Add the task-ledger check to Swift CI after
  the workflow and checker both exist. Extend the workflow paths to the task
  implementation plan, task and scenario ledgers, plus
  `tools/check-task-ledger.mjs`, so an alignment-only change cannot skip its
  validator.
  _Depends: M0-05b, M0-09ac._
  _Verify: a pull-request run completes the ledger step._
- **M0-11** _(Infrastructure)_ — Add proof-mode consistency checks: parse
  each scenario's `(Proof: …)` marker (default `unit`; group 18 defaults to
  `benchmark`), derive the scenario census from scenarios.md instead of any
  hand-maintained count, verify greens ownership by mode (suite and
  release-configuration scenarios on behavior tasks or gates; every other
  mode only on behavior tasks), and verify verification commands per mode:
  behavior filters expand to exactly their unit- and exit-test greens,
  exit-test greens appear in both `test` and `test:release` filters,
  compile-fail greens require `test:compilefail`, benchmark greens carry the
  recorded-result obligation, and simulator and floor greens name their runs.
  _Depends: M0-09ab._
  _Verify: `mise run tasks:check` plus mode-mismatch, gate-ownership,
  missing-release-filter, and over-broad-filter fixtures._
- **M0-12** _(Infrastructure)_ — Add graph-order invariants: _Release_ tasks
  form one dependency-ordered chain; every _Release_ task transitively
  depends on a _Gate_; and the M6 arena-integration filters, expanded
  against scenarios.md, cover every unit- and exit-test-mode scenario owned
  by M1–M6 tasks except the exceptions the M6 section's arena-coverage note
  names.
  _Depends: M0-11._
  _Verify: `mise run tasks:check` plus forked-release-chain, gateless-release,
  and integration-hole fixtures._
- **M0-10** _(Gate)_ — Close scaffolding with every local command and CI job
  green on the stub.
  _Depends: M0-05c, M0-06, M0-08, M0-09b, M0-12._
  _Verify: `mise run fmt:check`, `mise run tasks:check`,
  `mise run test:matrix`, `mise run test:release`, and
  `mise run test:compilefail`._

## M1 tasks

_Plan scope and exit: [M1: Simple correctness core](./plan.md#plan-m1)._

- **M1-01a** _(Infrastructure)_ — Add final-class descriptors, stable
  `ObjectIdentifier` identity, human labels, and `ManualCog<T>` ref values.
  _Depends: M0-10._
  _Verify: `mise run test --filter M1DescriptorInfrastructure`._
- **M1-34a** _(Decision)_ — Settle production-install and testing-factory
  helper spellings before either helper or its call sites exist; record the
  choice in §10 and the Swift README snapshot.
  _Depends: M0-10._
  _Verify: recorded decision, API sketch, and call-site vocabulary search._
- **M1-01b** _(Behavior)_ — Add descriptor-plus-key node storage, the
  `CogTesting` isolated-context factory, and untracked manual reads.
  _Depends: M1-01a, M1-34a._
  _Verify: `mise run test --filter 'DECL-01|ONE-04'`._
  _Greens: DECL-01, ONE-04._
- **M1-01ca** _(Infrastructure)_ — Give testing contexts an injected clock
  protocol from day one.
  _Depends: M1-01b._
  _Verify: `mise run test --filter CogTestingClockInfrastructure`._
- **M1-01cb** _(Infrastructure)_ — Add deterministic MainActor cleanup
  acknowledgement primitives to `CogTesting` without exposing graph storage.
  _Depends: M1-01b._
  _Verify: `mise run test --filter CogTestingAcknowledgementInfrastructure`._
- **M1-02** _(Behavior)_ — Add `ManualCogBox`, constant and closure starting
  values, allocation-free `box[key]` refs, and per-key state identity.
  _Depends: M1-01b._
  _Verify: `mise run test --filter 'DECL-02|DECL-03|DECL-04'`._
  _Greens: DECL-02, DECL-03, DECL-04._
- **M1-03** _(Behavior)_ — Add `.readOnly`; verify reads and the rejected
  writer subscript fixture.
  _Depends: M1-02._
  _Verify: `mise run test --filter DECL-05` and `mise run test:compilefail`._
  _Greens: DECL-05, DECL-06._
- **M1-04aa** _(Infrastructure)_ — Add idle, accumulating, and flushing
  phases, default/custom commit-name capture, unforgeable turn IDs, and
  keyless pending/current storage.
  _Depends: M1-01b._
  _Verify: `mise run test --filter TurnStateInfrastructure`._
- **M1-04ab** _(Behavior)_ — Add keyless staging, writer read-back, flush on
  the outer commit boundary, and committed normal reads during accumulation.
  _Depends: M1-04aa._
  _Verify: `mise run test --filter 'READ-01|TURN-01|TURN-03|TURN-04'`._
  _Greens: READ-01, TURN-01, TURN-03, TURN-04._
- **M1-04b** _(Behavior)_ — Add repeated and keyed staging semantics.
  _Depends: M1-02, M1-04ab._
  _Verify: `mise run test --filter 'TURN-02|TURN-14'`._
  _Greens: TURN-02, TURN-14._
- **M1-05a** _(Behavior)_ — Add keyless derived cogs, tracked `c.get`, lazy
  first computation, and caching.
  _Depends: M1-04ab._
  _Verify: `mise run test --filter 'DECL-07|DECL-09|READ-02'`._
  _Greens: DECL-07, DECL-09, READ-02._
- **M1-05b** _(Behavior)_ — Add derived boxes and lexical keyed capture.
  _Depends: M1-02, M1-05a._
  _Verify: `mise run test --filter DECL-08`._
  _Greens: DECL-08._
- **M1-05c** _(Behavior)_ — Add the throwing-selector compile-fail fixture.
  _Depends: M1-05a._
  _Verify: `mise run test:compilefail`._
  _Greens: DECL-12._
- **M1-06aa** _(Infrastructure)_ — Add CLEAN/CHECK/DIRTY state, versions, and
  reusable explicit-stack enter/exit frames.
  _Depends: M1-05a._
  _Verify: `mise run test --filter SettleEngineInfrastructure`._
- **M1-06ab** _(Behavior)_ — Settle a linear chain through the explicit stack
  from the newest committed source value.
  _Depends: M1-06aa._
  _Verify: `mise run test --filter GRAPH-01`._
  _Greens: GRAPH-01._
- **M1-06b** _(Behavior)_ — Add multi-parent checking so multi-source commits
  and diamonds settle once.
  _Depends: M1-06ab._
  _Verify: `mise run test --filter 'READ-03|GRAPH-02'`._
  _Greens: READ-03, GRAPH-02._
- **M1-06c** _(Behavior)_ — Add broad lazy pull so only read branches compute.
  _Depends: M1-06ab._
  _Verify: `mise run test --filter GRAPH-04`._
  _Greens: GRAPH-04._
- **M1-07a** _(Behavior)_ — Equality-gate manual writes with `Equatable`,
  custom `equals:`, non-`Equatable` assume-change, and staged reversion.
  _Depends: M1-04b, M1-06ab._
  _Verify: `mise run test --filter 'TURN-09|TURN-10|TURN-11|TURN-12'`._
  _Greens: TURN-09, TURN-10, TURN-11, TURN-12._
- **M1-07b** _(Behavior)_ — Equality-gate derived recomputation and stop or
  continue downstream waves accordingly.
  _Depends: M1-06b, M1-07a._
  _Verify: `mise run test --filter 'GRAPH-05|GRAPH-06'`._
  _Greens: GRAPH-05, GRAPH-06._
- **M1-08a** _(Behavior)_ — Keep cold cogs dirty without recomputing and catch
  them up once after any number of turns.
  _Depends: M1-06ab._
  _Verify: `mise run test --filter 'GRAPH-07|GRAPH-08'`._
  _Greens: GRAPH-07, GRAPH-08._
- **M1-08b** _(Behavior)_ — Add subscription-free one-shot `cogs.read` that
  still settles.
  _Depends: M1-08a._
  _Verify: `mise run test --filter READ-07`._
  _Greens: READ-07._
- **M1-09a** _(Behavior)_ — Recapture dependencies across conditionals and
  early returns.
  _Depends: M1-06ab._
  _Verify: `mise run test --filter 'GRAPH-09|GRAPH-10'`._
  _Greens: GRAPH-09, GRAPH-10._
- **M1-09b** _(Behavior)_ — Remove dropped keyed dependencies and recapture
  ref-through-ref indirection.
  _Depends: M1-05b, M1-09a._
  _Verify: `mise run test --filter 'GRAPH-11|GRAPH-12'`._
  _Greens: GRAPH-11, GRAPH-12._
- **M1-09c** _(Behavior)_ — Add `c.read` peeks that skip edges but settle.
  _Depends: M1-08b, M1-09a._
  _Verify: `mise run test --filter READ-06`._
  _Greens: READ-06._
- **M1-10** _(Behavior)_ — Add `c.curr`, including the no-previous first run.
  _Depends: M1-05a._
  _Verify: `mise run test --filter 'READ-04|READ-05'`._
  _Greens: READ-04, READ-05._
- **M1-11** _(Behavior)_ — Stress the existing explicit stack with a chain
  deep enough to overflow recursion.
  _Depends: M1-06ab._
  _Verify: `mise run test --filter GRAPH-03`._
  _Greens: GRAPH-03._
- **M1-31a** _(Behavior)_ — Add bounded debug history with named turns,
  writes, and recomputations.
  _Depends: M1-06b, M1-07a._
  _Verify: `mise run test --filter 'HIST-01|HIST-02|HIST-03'`._
  _Greens: HIST-01, HIST-02, HIST-03._
- **M1-12a** _(Infrastructure)_ — Add nested-turn joining, sibling-turn
  separation, and flush boundaries without yet claiming the reaction/history
  stories.
  _Depends: M1-04b._
  _Verify: `mise run test --filter TurnCompositionInfrastructure`._
- **M1-13a** _(Infrastructure)_ — Add the non-reentrant FIFO turn queue used
  while flushing.
  _Depends: M1-12a._
  _Verify: `mise run test --filter TurnQueueInfrastructure`._
- **M1-14** _(Behavior)_ — Reject an escaped writer in debug and release with
  Swift Testing exit tests.
  _Depends: M1-04ab._
  _Verify: `mise run test --filter TURN-07` and
  `mise run test:release --filter TURN-07`._
  _Greens: TURN-07._
- **M1-15a** _(Decision)_ — Settle the failure mode for a selector that calls
  an op while computing; update §10, the Swift snapshot, scenarios, and tasks.
  Reserve the `M1-15e*` branch for any new behavior tasks.
  _Depends: M1-12a._
  _Verify: recorded decision, final-gate dependency update, and
  `mise run tasks:check`._
- **M1-15b** _(Infrastructure)_ — Add computing marks and full
  descriptor-and-key cycle paths over the explicit stack.
  _Depends: M1-09b, M1-15a._
  _Verify: internal self, multi-node, and keyed cycle probes._
- **M1-15c** _(Behavior)_ — Add conditional/keyed cycle reporting and the
  narrow `CogTesting` diagnostic seam.
  _Depends: M1-15b._
  _Verify: `mise run test --filter 'CYCLE-03|CYCLE-04|CYCLE-05'`._
  _Greens: CYCLE-03, CYCLE-04, CYCLE-05._
- **M1-15d** _(Behavior)_ — Prove self and multi-node cycle failure in debug
  and release with exit tests.
  _Depends: M1-15c._
  _Verify: `mise run test --filter 'CYCLE-01|CYCLE-02'` and
  `mise run test:release --filter 'CYCLE-01|CYCLE-02'`._
  _Greens: CYCLE-01, CYCLE-02._
- **M1-31b** _(Behavior)_ — Show explicit and `fileID:line` labels in both
  cycle diagnostics and debug history.
  _Depends: M1-15c, M1-31a._
  _Verify: `mise run test --filter 'DECL-10|DECL-11'`._
  _Greens: DECL-10, DECL-11._
- **M1-16a** _(Decision)_ — Settle when a reaction registered during a flush
  performs its initial tracking run; update §10, snapshot, scenarios, and
  tasks, using the `M1-16e*` branch for any new behavior tasks.
  _Depends: M1-13a._
  _Verify: recorded decision, final-gate dependency update, and
  `mise run tasks:check`._
- **M1-16b** _(Behavior)_ — Add immediate reaction registration, changed
  dependency wake-up, and unrelated-turn quietness.
  _Depends: M1-07b, M1-16a._
  _Verify: `mise run test --filter 'REACT-01|REACT-02|REACT-03'`._
  _Greens: REACT-01, REACT-02, REACT-03._
- **M1-16c** _(Behavior)_ — Add settled reads, registration order, and
  dependency retracking for reactions.
  _Depends: M1-09a, M1-16b._
  _Verify: `mise run test --filter 'REACT-04|REACT-05|REACT-06'`._
  _Greens: REACT-04, REACT-05, REACT-06._
- **M1-16d** _(Behavior)_ — Prove reaction completion before the committing op
  returns.
  _Depends: M1-16c._
  _Verify: `mise run test --filter REACT-07`._
  _Greens: REACT-07._
- **M1-12b** _(Behavior)_ — Verify nested and sibling turns end to end through
  real reactions and history.
  _Depends: M1-16d, M1-31a._
  _Verify: `mise run test --filter 'TURN-05|TURN-06|TURN-13'`._
  _Greens: TURN-05, TURN-06, TURN-13._
- **M1-17** _(Behavior)_ — Add `watch(_:initial:name:)` with `.skip` and
  `.run`, including old/new delivery.
  _Depends: M1-16c._
  _Verify: `mise run test --filter 'REACT-08|REACT-09'`._
  _Greens: REACT-08, REACT-09._
- **M1-18a** _(Behavior)_ — Add idempotent cancellation and shared-copy
  identity for `ReactionToken`.
  _Depends: M1-16b._
  _Verify: `mise run test --filter 'REACT-10|REACT-11|REACT-13'`._
  _Greens: REACT-10, REACT-11, REACT-13._
- **M1-18b** _(Behavior)_ — Cancel the registration when the last token copy
  deinitializes.
  _Depends: M1-18a._
  _Verify: `mise run test --filter REACT-12`._
  _Greens: REACT-12._
- **M1-19a** _(Behavior)_ — Give reactions a read-only controller and add its
  compile-fail write fixture.
  _Depends: M1-03, M1-16b._
  _Verify: `mise run test:compilefail`._
  _Greens: REACT-14._
- **M1-19b** _(Behavior)_ — Do not wake a reaction when its derived dependency
  recomputes equal.
  _Depends: M1-16c._
  _Verify: `mise run test --filter REACT-21`._
  _Greens: REACT-21._
- **M1-20a** _(Behavior)_ — Queue one op called by a reaction as a new turn.
  _Depends: M1-16d._
  _Verify: `mise run test --filter REACT-15`._
  _Greens: REACT-15._
- **M1-20b** _(Behavior)_ — Drain a chain of reaction write-backs one settled
  turn at a time.
  _Depends: M1-20a._
  _Verify: `mise run test --filter REACT-16`._
  _Greens: REACT-16._
- **M1-13b** _(Behavior)_ — Verify several commits queued during one flush
  complete in FIFO settle-notify-react order.
  _Depends: M1-20b._
  _Verify: `mise run test --filter TURN-08`._
  _Greens: TURN-08._
- **M1-21** _(Behavior)_ — Add the debug quiescence warning, causal chain,
  deterministic diagnostic seam, and synchronous return to idle.
  _Depends: M1-20b, M1-31a._
  _Verify: `mise run test --filter REACT-17`._
  _Greens: REACT-17._
- **M1-22** _(Behavior)_ — Acknowledge cross-executor token-deinit cleanup on
  the MainActor.
  _Depends: M1-01cb, M1-18b._
  _Verify: `mise run test --filter REACT-18`._
  _Greens: REACT-18._
- **M1-31c** _(Behavior)_ — Record named watch/effect runs in history.
  _Depends: M1-17, M1-31a._
  _Verify: `mise run test --filter HIST-05`._
  _Greens: HIST-05._
- **M1-31d** _(Infrastructure)_ — Display bounded debug history through
  `os_log` without making display part of graph correctness.
  _Depends: M1-31c._
  _Verify: focused debug smoke test plus `mise run fmt:check`._
- **M1-23a** _(Decision)_ — Settle adding a token to an already-cancelled
  `EffectGroup`; update §10, snapshot, scenarios, and tasks, using the
  `M1-23d*` branch for any new behavior tasks.
  _Depends: M1-18a._
  _Verify: recorded decision, final-gate dependency update, and
  `mise run tasks:check`._
- **M1-23b** _(Behavior)_ — Add group ownership, `add`, shared copies, and
  idempotent explicit cancellation.
  _Depends: M1-23a._
  _Verify: `mise run test --filter 'GROUP-01|GROUP-03|GROUP-05'`._
  _Greens: GROUP-01, GROUP-03, GROUP-05._
- **M1-23c** _(Behavior)_ — Cancel all owned effects when the final group copy
  deinitializes.
  _Depends: M1-23b._
  _Verify: `mise run test --filter GROUP-04`._
  _Greens: GROUP-04._
- **M1-24a** _(Behavior)_ — Add `group.task(name:)` and propagate explicit
  group cancellation to the task.
  _Depends: M1-23b._
  _Verify: `mise run test --filter GROUP-02`._
  _Greens: GROUP-02._
- **M1-24b** _(Behavior)_ — Drive the named hourly task with the injected
  clock and record its turn in history.
  _Depends: M1-01ca, M1-24a, M1-31a._
  _Verify: `mise run test --filter GROUP-06`._
  _Greens: GROUP-06._
- **M1-25** _(Behavior)_ — Add inert effects declarations and explicit
  `install(in:)` with screen-scoped cancellation that preserves app state.
  _Depends: M1-23b._
  _Verify: `mise run test --filter 'GROUP-07|GROUP-08'`._
  _Greens: GROUP-07, GROUP-08._
- **M1-26** _(Behavior)_ — Acknowledge cross-executor group-deinit cleanup and
  verify registrations and tasks are cancelled.
  _Depends: M1-01cb, M1-23c, M1-24a._
  _Verify: `mise run test --filter GROUP-09`._
  _Greens: GROUP-09._
- **M1-27a** _(Behavior)_ — Add manual `.app` default and derived `keepAlive`
  sugar.
  _Depends: M1-08a._
  _Verify: `mise run test --filter 'LIFE-01|LIFE-06'`._
  _Greens: LIFE-01, LIFE-06._
- **M1-27b** _(Behavior)_ — Count a registered reaction as an external lease.
  _Depends: M1-16b, M1-27a._
  _Verify: `mise run test --filter LIFE-07`._
  _Greens: LIFE-07._
- **M1-28a** _(Behavior)_ — Release an unobserved derived cog after injected
  grace and recreate it correctly.
  _Depends: M1-01ca, M1-27a._
  _Verify: `mise run test --filter 'LIFE-02|LIFE-03'`._
  _Greens: LIFE-02, LIFE-03._
- **M1-28b** _(Behavior)_ — Cancel pending release when a consumer returns
  within grace.
  _Depends: M1-28a._
  _Verify: `mise run test --filter LIFE-04`._
  _Greens: LIFE-04._
- **M1-28c** _(Behavior)_ — Reset opted-in manual state to its initial value
  after release.
  _Depends: M1-02, M1-28a._
  _Verify: `mise run test --filter LIFE-05`._
  _Greens: LIFE-05._
- **M1-28d** _(Behavior)_ — Prove internal graph edges never act as leases.
  _Depends: M1-09a, M1-28a._
  _Verify: `mise run test --filter LIFE-09`._
  _Greens: LIFE-09._
- **M1-29a** _(Behavior)_ — Install one production context shared app-wide.
  _Depends: M1-01b._
  _Verify: `mise run test --filter ONE-01`._
  _Greens: ONE-01._
- **M1-29b** _(Behavior)_ — Reject a second production install in debug and
  release and reject public plain construction at compile time.
  _Depends: M1-29a._
  _Verify: `mise run test --filter ONE-02`,
  `mise run test:release --filter ONE-02`, and `mise run test:compilefail`._
  _Greens: ONE-02, ONE-03._
- **M1-29c** _(Behavior)_ — Keep isolated tests and previews independent of
  one another and the production guard.
  _Depends: M1-29b._
  _Verify: `mise run test --filter ONE-05`._
  _Greens: ONE-05._
- **M1-29d** _(Behavior)_ — Preserve manual app state across scene
  reconstruction.
  _Depends: M1-29a, M1-27a._
  _Verify: `mise run test --filter ONE-06`._
  _Greens: ONE-06._
- **M1-34b** _(Infrastructure)_ — Document the final production-install and
  isolated-testing usage after both paths are proven end to end.
  _Depends: M1-29c, M1-29d._
  _Verify: README call-site review plus `mise run fmt:check`._
- **M1-30a** _(Behavior)_ — Add debug-only manual-source `seed` and dirty
  propagation without a turn.
  _Depends: M1-07a, M1-09a._
  _Verify: `mise run test --filter 'SEED-01|SEED-03'`._
  _Greens: SEED-01, SEED-03._
- **M1-30b** _(Behavior)_ — Prove seed is quiet for history and reactions and
  run the §6.6 alert story verbatim.
  _Depends: M1-16c, M1-30a, M1-31a._
  _Verify: `mise run test --filter 'SEED-02|SEED-04'`._
  _Greens: SEED-02, SEED-04._
- **M1-30c** _(Behavior)_ — Reject seeding a derived cog at compile time.
  _Depends: M1-30a._
  _Verify: `mise run test:compilefail`._
  _Greens: SEED-06._
- **M1-33a** _(Behavior)_ — Add the off-actor compile-fail fixture and prove
  non-`Sendable` MainActor values need no wrapper.
  _Depends: M1-05a._
  _Verify: `mise run test:compilefail` and
  `mise run test --filter ACTOR-03`._
  _Greens: ACTOR-02, ACTOR-03._
- **M1-33b** _(Behavior)_ — Prove selectors, commit bodies, and reactions run
  on the MainActor in every build-settings leg.
  _Depends: M1-16b, M1-33a._
  _Verify: `mise run test:matrix --filter ACTOR-01`._
  _Greens: ACTOR-01._
- **M1-33c** _(Gate)_ — Run the complete host-runnable M1 suite in all four
  build-settings legs.
  _Depends: M1-05c, M1-06c, M1-09c, M1-10, M1-11, M1-12b, M1-13b,
  M1-14, M1-15d, M1-19a, M1-19b, M1-21, M1-22, M1-24b, M1-25,
  M1-26, M1-27b, M1-28b, M1-28c, M1-28d, M1-30b, M1-30c,
  M1-31b, M1-31d, M1-33b, M1-34b._
  _Verify: `mise run test:matrix` and `mise run test:compilefail`._
  _Greens: LEG-01._
- **M1-32** _(Gate)_ — Prove the completed M1 suite and every-build guards in
  release, including absent seed and zero-cost history.
  _Depends: M1-33c._
  _Verify: `mise run test:release` plus release API/build checks._
  _Greens: SEED-05, HIST-04, LEG-03._

## M2 tasks

_Plan scope and exit: [M2: SwiftUI boundary and Weather](./plan.md#plan-m2)._

- **M2-17a** _(Decision)_ — In the smallest tracked-view prototype, compare
  `cogs.get(ref)`, `cogs[ref]`, and callable refs before boundary call sites
  multiply.
  _Depends: M1-32._
  _Verify: checked-in prototype diff and decision rationale._
- **M2-17b** _(Infrastructure)_ — Apply the winning spelling and record it in
  §10 and the Swift README snapshot.
  _Depends: M2-17a._
  _Verify: API call-site search plus `mise run fmt:check`._
- **M2-01** _(Infrastructure)_ — Add registrar-backed boundary objects,
  one phantom key path, lazy per-node storage, and change-only mutation.
  _Depends: M2-17b._
  _Verify: focused registrar infrastructure tests._
- **M2-02aa** _(Behavior)_ — Add the `\.cogs` environment key and prove views
  resolve the installed app context through it.
  _Depends: M2-01._
  _Verify: `mise run test --filter UI-06`._
  _Greens: UI-06._
- **M2-02ab** _(Behavior)_ — Add tracked view reads with changed-value and
  unrelated-write behavior.
  _Depends: M2-02aa._
  _Verify: `mise run test --filter 'UI-01|UI-02'`._
  _Greens: UI-01, UI-02._
- **M2-02b** _(Behavior)_ — Prove only UI-read nodes receive boundary objects
  and interior nodes never do.
  _Depends: M2-02ab._
  _Verify: `mise run test --filter UI-05`._
  _Greens: UI-05._
- **M2-03** _(Behavior)_ — Notice only readers of the written keyed value.
  _Depends: M2-02ab._
  _Verify: `mise run test --filter UI-03`._
  _Greens: UI-03._
- **M2-04** _(Behavior)_ — Suppress UI notice when recomputation lands equal.
  _Depends: M2-02ab._
  _Verify: `mise run test --filter UI-04`._
  _Greens: UI-04._
- **M2-05** _(Behavior)_ — Add `binding(for:)` with named history commits and
  immediate read-back.
  _Depends: M2-02ab._
  _Verify: `mise run test --filter 'UI-07|UI-08'`._
  _Greens: UI-07, UI-08._
- **M2-06** _(Behavior)_ — Keep one-shot reads in view bodies unsubscribed.
  _Depends: M2-02ab._
  _Verify: `mise run test --filter UI-09`._
  _Greens: UI-09._
- **M2-07** _(Behavior)_ — Warn through the diagnostic seam when a tracked
  read has no consumer.
  _Depends: M2-02ab._
  _Verify: `mise run test --filter UI-10`._
  _Greens: UI-10._
- **M2-08** _(Behavior)_ — Prove a view reading a changed pair renders only
  the old or new pair.
  _Depends: M2-02ab._
  _Verify: `mise run test --filter UI-13`._
  _Greens: UI-13._
- **M2-09** _(Behavior)_ — Notify changed boundaries before reactions and
  record each notice with its label.
  _Depends: M2-02ab._
  _Verify: `mise run test --filter 'REACT-19|HIST-06'`._
  _Greens: REACT-19, HIST-06._
- **M2-10** _(Behavior)_ — Pin a node after its first UI read for the app
  context's lifetime.
  _Depends: M2-02ab._
  _Verify: `mise run test --filter LIFE-08`._
  _Greens: LIFE-08._
- **M2-11** _(Behavior)_ — Prove UIKit automatic tracking on an iOS 26
  simulator behind `#if canImport(UIKit)`.
  _Depends: M2-02ab._
  _Verify: simulator `CogBoundaryTests` filtered to UI-11._
  _Greens: UI-11._
- **M2-12** _(Behavior)_ — Prove AppKit automatic tracking on the macOS host.
  _Depends: M2-02ab._
  _Verify: `mise run test --filter UI-12`._
  _Greens: UI-12._
- **M2-13a** _(Infrastructure)_ — Add the simulator CI job after the UIKit
  boundary target exists.
  _Depends: M2-11._
  _Verify: `test-simulator` completes only `CogBoundaryTests`._
- **M2-14** _(Infrastructure)_ — Build Weather's state layer with per-ZIP
  sources, `fileprivate` access plus ops, and its effects group.
  _Depends: M2-05, M2-10._
  _Verify: Weather scheme builds after the state layer change._
- **M2-15** _(Infrastructure)_ — Build Weather cards, bindings, and per-ZIP
  tracked reads.
  _Depends: M2-14._
  _Verify: Weather scheme builds and launches in the simulator._
- **M2-16** _(Gate)_ — Verify Weather with deterministic render counters: one
  ZIP invalidates one card, pairs never tear, and notices precede reactions.
  _Depends: M2-03, M2-08, M2-09, M2-15._
  _Verify: Weather integration tests using counters, never log scraping._
- **M2-13b** _(Infrastructure)_ — Add the Weather build CI job only after the
  example exists.
  _Depends: M2-15._
  _Verify: the Weather build job passes in CI._
- **M2-18a** _(Decision)_ — Time-box investigation of pinned iOS 17 runtime
  installation; record exact mechanics and whether runner availability can
  block a release. The nightly remains non-blocking unless this task records
  a reliable hosted runtime.
  _Verify: reproducible install command or documented non-blocking fallback._
- **M2-18b** _(Behavior)_ — Add the pinned nightly floor subset when the
  recorded runtime path is available.
  _Depends: M2-04, M2-05, M2-18a._
  _Non-blocking: execute when M2-18a records a reliable hosted runtime;
  otherwise leave deferred without blocking M2-20 or a release._
  _Verify: a scheduled or manually dispatched floor job passes UI-14._
  _Greens: UI-14._
- **M2-19** _(Behavior)_ — With a real boundary installed, prove debug seed
  sends no UI notice.
  _Depends: M2-02ab._
  _Verify: `mise run test --filter SEED-07`._
  _Greens: SEED-07._
- **M2-20** _(Gate)_ — Close M2 across host, simulator, Weather, and all
  available floor checks.
  _Depends: M2-02b, M2-04, M2-06, M2-07, M2-12, M2-13a, M2-13b,
  M2-16, M2-18a, M2-19._
  _Verify: `mise run test:matrix`, `test-simulator`, and the Weather build;
  floor job when available under M2-18a's recorded policy._

## M3 tasks

_Plan scope and exit: [M3: First async slice](./plan.md#plan-m3)._

- **M3-01** _(Behavior)_ — Add `CogPhase`, `Previous`, `latestValue`, and
  `isLoading` value semantics with exhaustive phase accessor tests.
  _Depends: M2-20._
  _Verify: `mise run test --filter ASYNC-04`._
  _Greens: ASYNC-04._
- **M3-02** _(Behavior)_ — On first tracked read, start work, publish pending
  as a turn, and expose no initial phase.
  _Depends: M3-01._
  _Verify: `mise run test --filter ASYNC-01`._
  _Greens: ASYNC-01._
- **M3-03a** _(Behavior)_ — Commit success and failure as distinct named
  turns observed by watchers.
  _Depends: M3-02._
  _Verify: `mise run test --filter 'ASYNC-02|ASYNC-06'`._
  _Greens: ASYNC-02, ASYNC-06._
- **M3-03b** _(Behavior)_ — Preserve explicit `Previous.some(nil)` for
  optional successes.
  _Depends: M3-03a._
  _Verify: `mise run test --filter ASYNC-03`._
  _Greens: ASYNC-03._
- **M3-03c** _(Behavior)_ — Record initial pending and failure as separate
  watcher/history turns with no previous value.
  _Depends: M3-03a._
  _Verify: `mise run test --filter ASYNC-18`._
  _Greens: ASYNC-18._
- **M3-04** _(Behavior)_ — Add `.latest` optional projection and suppress
  downstream change for equal reload results.
  _Depends: M3-03a._
  _Verify: `mise run test --filter 'ASYNC-05|ASYNC-20'`._
  _Greens: ASYNC-05, ASYNC-20._
- **M3-05a** _(Behavior)_ — Cancel and replace in-flight latest work without
  publishing cancellation as failure.
  _Depends: M3-03a._
  _Verify: `mise run test --filter 'ASYNC-07|ASYNC-09'`._
  _Greens: ASYNC-07, ASYNC-09._
- **M3-05b** _(Behavior)_ — Reject stale results from work that ignores
  cancellation.
  _Depends: M3-05a._
  _Verify: `mise run test --filter ASYNC-08`._
  _Greens: ASYNC-08._
- **M3-05c** _(Behavior)_ — Carry the last good value through failed and
  repeated reload pendings.
  _Depends: M3-03b, M3-05a._
  _Verify: `mise run test --filter ASYNC-19`._
  _Greens: ASYNC-19._
- **M3-06** _(Behavior)_ — Capture dependencies only in the synchronous
  selector before it returns `Work`.
  _Depends: M3-02._
  _Verify: `mise run test --filter ASYNC-11`._
  _Greens: ASYNC-11._
- **M3-07** _(Behavior)_ — Fetch and phase `AsyncCogBox` keys independently.
  _Depends: M3-05a._
  _Verify: `mise run test --filter ASYNC-12`._
  _Greens: ASYNC-12._
- **M3-08a** _(Decision)_ — Settle one-shot reads and refreshes of never-read
  async refs; update §10, snapshot, scenarios, and tasks before implementing
  refresh, using the `M3-08c*` branch for any additional behavior tasks.
  _Depends: M3-02._
  _Verify: recorded decision, any `M3-08c*` terminal added to M3-11, and
  `mise run tasks:check`._
- **M3-08b** _(Behavior)_ — Refresh settled or in-flight latest work under
  the same replacement and generation rules.
  _Depends: M3-05b, M3-08a._
  _Verify: `mise run test --filter 'ASYNC-10|ASYNC-21'`._
  _Greens: ASYNC-10, ASYNC-21._
- **M3-09** _(Behavior)_ — Cancel work and advance generation on release;
  recreate without accepting late results.
  _Depends: M3-05b._
  _Verify: `mise run test --filter 'ASYNC-13|ASYNC-14'`._
  _Greens: ASYNC-13, ASYNC-14._
- **M3-10a** _(Behavior)_ — Run work on the MainActor by default in every
  build-settings leg.
  _Depends: M3-02._
  _Verify: `mise run test:matrix --filter ASYNC-15`._
  _Greens: ASYNC-15._
- **M3-10b** _(Behavior)_ — Run `@concurrent` work off-main and commit its
  result on the MainActor under the generation check.
  _Depends: M3-05b, M3-10a._
  _Verify: `mise run test:matrix --filter ASYNC-16`._
  _Greens: ASYNC-16._
- **M3-10c** _(Behavior)_ — Expose descriptor-derived internal task names
  through the narrow testing seam.
  _Depends: M3-02._
  _Verify: `mise run test --filter ASYNC-17`._
  _Greens: ASYNC-17._
- **M3-11** _(Gate)_ — Close the deterministic async slice in every host leg
  and release configuration.
  _Depends: M3-03c, M3-04, M3-05c, M3-06, M3-07, M3-08b, M3-09,
  M3-10b, M3-10c._
  _Verify: `mise run test:matrix` and `mise run test:release`._

## M4 tasks

_Plan scope and exit: [M4: API review, docs, and 0.1.0](./plan.md#plan-m4)._

- **M4-01a** _(Decision)_ — Time-box a source review of swift-state-graph;
  compare tracked reads with capture lists and record a public-name decision
  matrix with prior-art credit.
  _Depends: M3-11._
  _Verify: checked-in review notes and proposed API delta._
- **M4-01b** _(Infrastructure)_ — Apply the approved public-name delta and
  update §10, the Swift snapshot, and attribution.
  _Depends: M4-01a._
  _Verify: full API call-site search, `mise run test:matrix`, and
  `mise run fmt:check`._
- **M4-02** _(Infrastructure)_ — Add the DocC landing page and Getting Started.
  _Depends: M4-01b._
  _Verify: local DocC archive builds without warnings._
- **M4-03** _(Infrastructure)_ — Add the one-context/testing article and start
  `CHANGELOG.md`.
  _Depends: M4-01b._
  _Verify: local DocC archive and `mise run fmt:check`._
- **M4-04a** _(Infrastructure)_ — Validate the package's macOS 14 deployment
  floor under the pinned Swift 6.2 toolchain.
  _Depends: M4-01b._
  _Verify: recorded clean host build and test commands._
- **M4-04b** _(Infrastructure)_ — Validate Weather's iOS 17 deployment floor
  under the same toolchain.
  _Depends: M4-01b._
  _Verify: recorded clean Weather archive or build command._
- **M4-04c** _(Behavior)_ — Build a minimal iOS 17 scratch app against the
  revision and close the aggregate platform-floor guarantee.
  _Depends: M4-04a, M4-04b._
  _Verify: recorded host, Weather, and scratch-app commands rerun cleanly._
  _Greens: LEG-04._
- **M4-05a** _(Infrastructure)_ — Create `swift-docs.yml`, build the DocC
  artifact locally, and exercise the Pages upload path without tagging.
  _Depends: M4-02, M4-03._
  _Verify: successful local archive and workflow dispatch artifact._
- **M4-05b** _(Gate)_ — Prepare the 0.1.0 release candidate without mutating
  remote state: format, ledgers, matrices, release, simulator, Weather, floor,
  docs, changelog, and revision-based scratch consumption.
  _Depends: M4-04c, M4-05a._
  _Verify: the complete 0.1.0 checklist with immutable CI links._
- **M4-05c** _(Release)_ — Create and push the bare annotated `0.1.0` tag.
  _Depends: M4-05b._
  _Verify: the remote tag resolves to the approved commit._
- **M4-05d** _(Gate)_ — Verify Pages and smoke-test exact 0.1.0
  consumption.
  _Depends: M4-05c._
  _Verify: live DocC URL and scratch `exact: "0.1.0"` build._
- **M4-05e** _(Release)_ — Create the 0.1.0 GitHub Release from the verified
  changelog excerpt.
  _Depends: M4-05d._
  _Verify: published GitHub Release points at the approved tag._

## M5 tasks

_Plan scope and exit: [M5: Benchmark port](./plan.md#plan-m5)._

- **M5-01a** _(Infrastructure)_ — Scaffold `CogScenarios` graph builders,
  in-selector counters, expected counts, and ref-layout parameterization.
  Start after the approved tag exists; Pages and GitHub Release verification
  may finish in parallel because later commits cannot change that tag.
  _Depends: M4-05c._
  _Verify: one sentinel graph reports its actual and expected counts._
- **M5-01b** _(Infrastructure)_ — Add `CogScenarioTests` and run the sentinel
  graph as a normal test.
  _Depends: M5-01a._
  _Verify: `mise run test --filter M5ScenarioSentinel`._
- **M5-02a** _(Behavior)_ — Port Kairo diamond and deep-chain cases.
  _Depends: M5-01b._
  _Verify: `mise run test --filter 'COUNT-01|COUNT-02'`._
  _Greens: COUNT-01, COUNT-02._
- **M5-02b** _(Behavior)_ — Port Kairo broad and unstable cases.
  _Depends: M5-01b._
  _Verify: `mise run test --filter 'COUNT-03|COUNT-04'`._
  _Greens: COUNT-03, COUNT-04._
- **M5-03a** _(Behavior)_ — Port dynamicBench sweeps.
  _Depends: M5-01b._
  _Verify: `mise run test --filter COUNT-05`._
  _Greens: COUNT-05._
- **M5-03b** _(Behavior)_ — Port the Cellx lattice.
  _Depends: M5-01b._
  _Verify: `mise run test --filter COUNT-06`._
  _Greens: COUNT-06._
- **M5-04a** _(Behavior)_ — Port keyed diamonds.
  _Depends: M5-01b._
  _Verify: `mise run test --filter COUNT-07`._
  _Greens: COUNT-07._
- **M5-04b** _(Behavior)_ — Port key churn and prove dropped keys stop
  running.
  _Depends: M5-04a._
  _Verify: `mise run test --filter COUNT-08`._
  _Greens: COUNT-08._
- **M5-05a** _(Infrastructure)_ — Scaffold the separate benchmark package
  shell and prove its dependencies cannot enter the shipped root package.
  _Depends: M5-01a._
  _Verify: both manifests describe successfully and the root dependency graph
  contains no benchmark-only package._
- **M5-05ba** _(Decision)_ — Verify the benchmark package's canonical
  repository and minimum version, exact ARC metric names, and baseline CLI;
  record those pins in the supported tool matrix.
  _Depends: M5-01a._
  _Verify: checked-in package, metric, and CLI compatibility table._
- **M5-05bb** _(Decision)_ — Probe allocator behavior across the Swift 6.2 to
  6.3 transition and MainActor benchmark compatibility; record the supported
  backends and any required isolation shim.
  _Depends: M5-05a, M5-05ba._
  _Verify: checked-in allocator/isolation compatibility table and probe logs._
- **M5-05c** _(Infrastructure)_ — Make one MainActor benchmark build and run,
  adding the pinned benchmark dependency, selected allocator configuration,
  and only the isolation shim proven necessary by the compatibility probes.
  _Depends: M5-05bb._
  _Verify: one MainActor benchmark builds and runs in the pinned environment._
- **M5-06** _(Behavior)_ — Add zero-allocation steady-turn and `box[key]`
  ref-creation benchmarks.
  _Depends: M5-05c, M5-02a, M5-04a._
  _Verify: benchmark filters for PERF-01 and PERF-06 report zero mallocs._
  _Greens: PERF-01, PERF-06._
- **M5-08a** _(Infrastructure)_ — Add pinned-environment baseline update and
  check commands with metadata recorded beside every baseline.
  _Depends: M5-06._
  _Verify: update then check the zero-allocation baseline unchanged._
- **M5-07a** _(Behavior)_ — Measure propagation ARC traffic and record the
  result and gate in `perf.md`.
  _Depends: M5-08a._
  _Verify: benchmark filter for PERF-02 plus recorded result._
  _Greens: PERF-02._
- **M5-07b** _(Behavior)_ — Measure 1,000-node peak memory, record its initial
  threshold, and turn the check green.
  _Depends: M5-08a._
  _Verify: benchmark filter for PERF-03 plus `perf.md` threshold._
  _Greens: PERF-03._
- **M5-07c** _(Behavior)_ — Measure lazy boundary-object count.
  _Depends: M5-08a._
  _Verify: benchmark filter for PERF-04 reports exactly the UI-read count._
  _Greens: PERF-04._
- **M5-07d** _(Behavior)_ — Measure pinned-key notice traffic, record its
  initial threshold, and turn the check green.
  _Depends: M5-08a._
  _Verify: benchmark filter for PERF-07 plus `perf.md` threshold._
  _Greens: PERF-07._
- **M5-08b** _(Infrastructure)_ — Add `mise run bench` and the non-gating
  `bench-build` CI job.
  _Depends: M5-07a, M5-07b, M5-07c, M5-07d._
  _Verify: local bench command and CI release build._
- **M5-09a** _(Infrastructure)_ — Put ref layout behind a test/benchmark
  candidate seam selected by `COG_TEST_REF_LAYOUT`; record inline
  `AnyHashable` as the baseline candidate.
  _Depends: M5-04b, M5-08b._
  _Verify: `COG_TEST_REF_LAYOUT=inline mise run test` and the keyed benchmark
  slice run through the seam._
- **M5-09b** _(Infrastructure)_ — Implement the interned-token candidate.
  _Depends: M5-09a._
  _Verify: `COG_TEST_REF_LAYOUT=interned mise run test --filter COUNT-07`._
- **M5-09c** _(Infrastructure)_ — Implement the generic-keyed-ref candidate.
  _Depends: M5-09a._
  _Verify: `COG_TEST_REF_LAYOUT=generic mise run test --filter COUNT-07`._
- **M5-09d** _(Behavior)_ — Run every behavior scenario through M5 unchanged
  under all three ref layouts; expose the loop as `mise run test:refs`.
  _Depends: M5-02b, M5-03a, M5-03b, M5-09b, M5-09c._
  _Verify: `mise run test:refs`._
  _Greens: COUNT-09._
- **M5-09e** _(Behavior)_ — Benchmark keyed diamonds and churn under every
  ref layout, record results, and settle the layout in `perf.md` and §10.
  _Depends: M5-09d._
  _Verify: recorded comparison and selected-layout rationale._
  _Greens: PERF-08._
- **M5-10** _(Gate)_ — Close M5 with scenario tests, benchmark build,
  baselines, records, and the selected ref layout green.
  _Depends: M4-05e, M5-09e._
  _Verify: `mise run test:matrix`, `mise run bench`, and baseline check._

## M6 tasks

_Plan scope and exit: [M6: Data-oriented core](./plan.md#plan-m6)._

_Arena-coverage exceptions: COUNT-01–COUNT-08 are proven under the arena core
by the `M6-05a` edge gate rather than an `M6-10` filter._

- **M6-01a** _(Infrastructure)_ — Add arena slot allocation, reuse,
  generations, and the scalar SoA column skeleton.
  _Depends: M5-10._
  _Verify: focused allocate, release, reuse, generation, and scalar-column
  tests._
- **M6-01b** _(Infrastructure)_ — Put the core and edge representations behind
  internal test-only `COG_TEST_CORE` and `COG_TEST_EDGE` selectors without
  changing the public API.
  _Depends: M6-01a._
  _Verify: selector sentinel tests under `COG_TEST_CORE=simple` and
  `COG_TEST_CORE=arena COG_TEST_EDGE=pool`._
- **M6-02** _(Infrastructure)_ — Implement the shared linked edge pool as the
  first runnable candidate.
  _Depends: M6-01b._
  _Verify: edge add, reuse, removal, and churn tests._
- **M6-06** _(Infrastructure)_ — Add typed per-descriptor current and pending
  value columns over arena slots.
  _Depends: M6-01a._
  _Verify: typed read, stage, commit, and removal tests._
- **M6-07aa** _(Infrastructure)_ — Stage and commit manual values through the
  arena and push dirty flags over baseline edges with a reused explicit stack.
  _Depends: M6-02, M6-06._
  _Verify: `COG_TEST_CORE=arena COG_TEST_EDGE=pool mise run test --filter
ArenaDirtyPropagationInfrastructure`._
- **M6-07ab** _(Infrastructure)_ — Pull and settle chain, diamond, and broad
  graphs with versions and equality backdating.
  _Depends: M6-07aa._
  _Verify: `COG_TEST_CORE=arena COG_TEST_EDGE=pool mise run test --filter
'GRAPH-01|GRAPH-02|GRAPH-04|GRAPH-05'`._
- **M6-07ac** _(Infrastructure)_ — Recapture dynamic dependencies and reuse or
  remove baseline edges as dependency sets change.
  _Depends: M6-07ab._
  _Verify: `COG_TEST_CORE=arena COG_TEST_EDGE=pool mise run test --filter
'GRAPH-09|GRAPH-10|GRAPH-11|COUNT-08'`._
- **M6-07b** _(Infrastructure)_ — Add arena computing marks and keyed cycle
  paths.
  _Depends: M6-07ac._
  _Verify: `COG_TEST_CORE=arena COG_TEST_EDGE=pool mise run test --filter CYCLE`._
- **M6-03** _(Infrastructure)_ — Implement Reactively-style per-node prefix
  arrays behind the runnable edge seam.
  _Depends: M6-07ac._
  _Verify: `COG_TEST_CORE=arena COG_TEST_EDGE=prefix mise run test --filter
'GRAPH|COUNT-08'`._
- **M6-04** _(Infrastructure)_ — Implement inline-plus-overflow behind the
  runnable edge seam.
  _Depends: M6-07ac._
  _Verify: `COG_TEST_CORE=arena COG_TEST_EDGE=inline mise run test --filter
'GRAPH|COUNT-08'`._
- **M6-05a** _(Gate)_ — Run the complete M5 scenario set under all three arena
  edge candidates. Candidate-specific repairs discovered here become separate
  tasks before this gate is retried.
  _Depends: M6-03, M6-04, M6-07b._
  _Verify: the complete M5 scenario set with `COG_TEST_CORE=arena` and each of
  `COG_TEST_EDGE=pool`, `prefix`, and `inline`._
- **M6-05b** _(Infrastructure)_ — Benchmark mostly-static and high-churn
  graphs under all correct edge candidates.
  _Depends: M6-05a._
  _Verify: pinned comparison result set._
- **M6-05c** _(Behavior)_ — Record the edge measurements and settle the
  layout in `perf.md` and §10.
  _Depends: M6-05b._
  _Verify: recorded decision and selected-candidate rerun._
  _Greens: PERF-09._
- **M6-08a** _(Infrastructure)_ — Integrate lazy boundary creation with arena
  slots.
  _Depends: M6-05c._
  _Verify: `COG_TEST_CORE=arena mise run test --filter 'UI-01|UI-02|UI-05'`._
- **M6-08b** _(Behavior)_ — Reuse released slots with new generations and
  catch stale access in debug.
  _Depends: M6-08a._
  _Verify: benchmark/test filter for PERF-05._
  _Greens: PERF-05._
- **M6-09** _(Infrastructure)_ — Integrate the debug ring buffer with zero
  release cost.
  _Depends: M6-05c._
  _Verify: `COG_TEST_CORE=arena mise run test --filter HIST` plus the arena
  release symbol/build check._
- **M6-10aa** _(Infrastructure)_ — Pass production/testing bootstrap,
  descriptors, and manual-source behavior through the arena selector.
  _Depends: M6-05c._
  _Verify: `COG_TEST_CORE=arena mise run test --filter 'ONE|DECL-0[1-5]'`._
- **M6-10ab** _(Infrastructure)_ — Pass writer staging, commit phases, and
  queued-turn behavior through the arena selector.
  _Depends: M6-10aa._
  _Verify: `COG_TEST_CORE=arena mise run test --filter TURN`._
- **M6-10ba** _(Infrastructure)_ — Pass tracked, untracked, lazy, equal, and
  dynamically recaptured derived reads, plus derived declaration and
  laziness behavior, through the arena selector.
  _Depends: M6-10ab._
  _Verify: `COG_TEST_CORE=arena mise run test --filter
'READ|GRAPH|DECL-0[7-9]'`._
- **M6-10bb** _(Infrastructure)_ — Pass public self, multi-node, conditional,
  and keyed cycle behavior through the arena selector.
  _Depends: M6-10ba._
  _Verify: `COG_TEST_CORE=arena mise run test --filter CYCLE` and
  `COG_TEST_CORE=arena mise run test:release --filter CYCLE`._
- **M6-10ca** _(Infrastructure)_ — Pass reaction tracking, ordering,
  equality, watch, token, and cleanup behavior, plus MainActor confinement
  and non-`Sendable` values, through the arena selector.
  _Depends: M6-10ba._
  _Verify: `COG_TEST_CORE=arena mise run test --filter
'REACT-(0[1-9]|1[0-4]|18|21)|ACTOR-0[13]'`._
- **M6-10cb** _(Infrastructure)_ — Pass reaction write-back, FIFO draining,
  and the quiescence diagnostic through the arena selector.
  _Depends: M6-10ca._
  _Verify: `COG_TEST_CORE=arena mise run test --filter
'REACT-15|REACT-16|REACT-17'`._
- **M6-10d** _(Infrastructure)_ — Pass effect-group and task behavior through
  the arena core selector.
  _Depends: M6-10cb._
  _Verify: `COG_TEST_CORE=arena mise run test --filter GROUP`._
- **M6-10ea** _(Infrastructure)_ — Pass app lifetime, keep-alive, external
  reaction leases, and UI pinning through arena lease counts.
  _Depends: M6-08b, M6-10ca._
  _Verify: `COG_TEST_CORE=arena mise run test --filter
'LIFE-01|LIFE-06|LIFE-07|LIFE-08'`._
- **M6-10eb** _(Infrastructure)_ — Pass grace cancellation, release,
  recreation, manual reset, and non-leasing internal edges through arena slot
  reuse.
  _Depends: M6-10ea._
  _Verify: `COG_TEST_CORE=arena mise run test --filter
'LIFE-02|LIFE-03|LIFE-04|LIFE-05|LIFE-09'`._
- **M6-10fa** _(Infrastructure)_ — Pass the M1 debug-seed semantics through
  arena dirty propagation without turns, reactions, or history.
  _Depends: M6-09, M6-10cb._
  _Verify: `COG_TEST_CORE=arena mise run test --filter 'SEED-0[1-4]'`,
  `mise run test:compilefail`, and the release absence check._
- **M6-10g** _(Infrastructure)_ — Pass UI boundary behavior and
  UI-before-reaction flush ordering through the arena core selector.
  _Depends: M6-08a, M6-10ca._
  _Verify: `COG_TEST_CORE=arena mise run test --filter 'UI|REACT-19'` plus
  UIKit simulator scenarios with `COG_TEST_CORE=arena`._
- **M6-10fb** _(Infrastructure)_ — Pass bounded history, explicit and
  `fileID:line` labels, named effect runs, and UI notices through the arena
  ring buffer and diagnostics.
  _Depends: M6-09, M6-10cb, M6-10g._
  _Verify: `COG_TEST_CORE=arena mise run test --filter 'HIST|DECL-1[01]'`
  plus the release zero-cost check._
- **M6-10fc** _(Infrastructure)_ — Prove seed stays silent at a real arena UI
  boundary.
  _Depends: M6-10fa, M6-10g._
  _Verify: `COG_TEST_CORE=arena mise run test --filter SEED-07`._
- **M6-10ha** _(Infrastructure)_ — Pass async phase creation, first work,
  results, projections, dependency capture, keys, isolation, and task naming
  through arena values.
  _Depends: M6-10ba._
  _Verify: `COG_TEST_CORE=arena mise run test --filter
'ASYNC-(0[1-6]|1[125678]|20)'`._
- **M6-10hb** _(Infrastructure)_ — Pass async replacement, refresh, stale
  generation rejection, previous-value carry, and release/recreation through
  arena generations.
  _Depends: M6-10eb, M6-10ha._
  _Verify: `COG_TEST_CORE=arena mise run test --filter
'ASYNC-(0[7-9]|10|1[349]|21)'`._
- **M6-10i** _(Behavior)_ — Run the complete behavior suite unchanged with
  the arena core selected in place of the simple one, leaving the default
  core untouched; expose simple-versus-arena checking as
  `mise run test:cores`. This task is outcome-neutral: it proves the arena,
  it does not adopt it.
  _Depends: M6-10bb, M6-10d, M6-10fb, M6-10fc, M6-10hb._
  _Verify: `mise run test:cores` and `mise run test:compilefail`._
  _Greens: COUNT-10._
- **M6-11a** _(Infrastructure)_ — Add the raw `@Observable` comparison
  adapter and equivalent benchmark workloads.
  _Depends: M6-10i._
  _Verify: comparator correctness and release benchmark build._
- **M6-11b** _(Infrastructure)_ — Add the swift-state-graph comparison adapter
  and equivalent workloads.
  _Depends: M6-10i._
  _Verify: comparator correctness and release benchmark build._
- **M6-11c** _(Infrastructure)_ — Run pinned simple, arena,
  swift-state-graph, and raw Observation comparisons and record results.
  _Depends: M6-11a, M6-11b._
  _Verify: complete pinned comparison result set in `perf.md`._
- **M6-11d** _(Behavior)_ — Select generous absolute thresholds and enable CI
  baseline gating, retaining the exact zero-malloc requirement.
  _Depends: M6-11c._
  _Verify: baseline check passes and a sentinel regression fails it._
  _Greens: PERF-10._
- **M6-12a** _(Decision)_ — Record what measurements settled and whether the
  arena replaces the simple core; update `perf.md`, §10, and the snapshot.
  _Depends: M6-11d._
  _Verify: recorded core decision and release recommendation._
- **M6-13** _(Infrastructure)_ — Execute the recorded core decision. If
  `M6-12a` approves replacement, switch the default core to the arena and
  rerun the complete suite; otherwise keep the simple core as the default and
  record the arena's retained selector-only role. The default core never
  changes upstream of this task.
  _Depends: M6-12a._
  _Verify: `mise run test:cores` with the default core matching the recorded
  decision._
- **M6-12b** _(Gate)_ — If the recorded decision calls for 0.2.0, prepare its
  non-mutating release candidate across behavior, benchmarks, docs, and
  changelog; otherwise close M6 with the recorded no-release rationale.
  _Depends: M6-13._
  _Verify: approved release checklist or approved no-release record._
- **M6-12c** _(Release)_ — Conditionally create and push the annotated `0.2.0`
  tag.
  _Depends: M6-12b._
  _Verify: remote tag resolves to the approved commit, or task is marked not
  applicable by M6-12a._
- **M6-12d** _(Gate)_ — Conditionally verify docs and exact 0.2.0
  consumption.
  _Depends: M6-12c._
  _Verify: post-release docs and scratch build, or not-applicable record._
- **M6-12e** _(Release)_ — Conditionally publish the 0.2.0 GitHub Release.
  _Depends: M6-12d._
  _Verify: published GitHub Release, or not-applicable record._

## M7 tasks

_Plan scope and exit: [M7: Async completion and exports](./plan.md#plan-m7)._

- **M7-01a** _(Decision)_ — Settle `.queue` failure independently; add its
  scenarios in the reserved `M7-03c*` task branch, then add that branch's
  terminal task to M7-16a.
  _Depends: M6-12b._
  _Verify: §10/snapshot decision plus `mise run tasks:check`._
- **M7-01b** _(Decision)_ — Settle natural stream termination independently;
  add its scenarios in the reserved `M7-06b*` task branch, then add that
  branch's terminal task to M7-16a.
  _Depends: M6-12b._
  _Verify: §10/snapshot decision plus `mise run tasks:check`._
- **M7-01c** _(Decision)_ — Settle throwing-stream failure independently;
  add its scenarios in the reserved `M7-06c*` task branch, then add that
  branch's terminal task to M7-16a.
  _Depends: M6-12b._
  _Verify: §10/snapshot decision plus `mise run tasks:check`._
- **M7-01d** _(Decision)_ — Settle equality for consecutive stream elements
  independently; add its scenarios in the reserved `M7-06d*` task branch,
  then add that branch's terminal task to M7-16a.
  _Depends: M6-12b._
  _Verify: §10/snapshot decision plus `mise run tasks:check`._
- **M7-02** _(Behavior)_ — Add `LatestPolicy`/`OrderedPolicy` type separation
  and reject ordered stream policies at compile time.
  _Depends: M6-12b._
  _Verify: `mise run test:compilefail`._
  _Greens: POLICY-05._
- **M7-03a** _(Behavior)_ — Run queued work one at a time in input order.
  _Depends: M7-01a, M7-02._
  _Verify: `mise run test --filter POLICY-01`._
  _Greens: POLICY-01._
- **M7-03b** _(Behavior)_ — Commit queued results in run order; the decision
  task owns failure scenarios in its reserved `M7-03c*` branch.
  _Depends: M7-03a._
  _Verify: `mise run test --filter POLICY-02`._
  _Greens: POLICY-02._
- **M7-04** _(Behavior)_ — Finish current exhaust work and run one catch-up
  from the newest state.
  _Depends: M7-02._
  _Verify: `mise run test --filter POLICY-03`._
  _Greens: POLICY-03._
- **M7-05** _(Behavior)_ — Overlap merged runs and commit each result as its
  own turn.
  _Depends: M7-02._
  _Verify: `mise run test --filter POLICY-04`._
  _Greens: POLICY-04._
- **M7-06a** _(Behavior)_ — Start latest stream work, show loading before the
  first element, and commit each element under the settled equality rule;
  decision tasks add termination, failure, and equality behavior only in their
  reserved `M7-06b*`, `M7-06c*`, and `M7-06d*` branches.
  _Depends: M7-01b, M7-01c, M7-01d, M7-02._
  _Verify: `mise run test --filter 'STREAM-01|STREAM-02'`._
  _Greens: STREAM-01, STREAM-02._
- **M7-07a** _(Behavior)_ — Cancel and replace streams on dependency change,
  rejecting late elements.
  _Depends: M7-06a._
  _Verify: `mise run test --filter STREAM-03`._
  _Greens: STREAM-03._
- **M7-07b** _(Behavior)_ — Cancel released live streams and reject their late
  elements.
  _Depends: M7-07a._
  _Verify: `mise run test --filter STREAM-04`._
  _Greens: STREAM-04._
- **M7-08** _(Behavior)_ — Add current-value-first multicast exports that
  settle cold cogs and then offer every changed value.
  _Depends: M6-12b._
  _Verify: `mise run test --filter 'EXPORT-01|EXPORT-02'`._
  _Greens: EXPORT-01, EXPORT-02._
- **M7-09a** _(Behavior)_ — Add non-blocking default `.newest(1)` overflow.
  _Depends: M7-08._
  _Verify: `mise run test --filter EXPORT-03`._
  _Greens: EXPORT-03._
- **M7-09b** _(Behavior)_ — Add exact `.oldest(n)` overflow.
  _Depends: M7-08._
  _Verify: `mise run test --filter EXPORT-04`._
  _Greens: EXPORT-04._
- **M7-09c** _(Behavior)_ — Add exact `.unbounded` delivery.
  _Depends: M7-08._
  _Verify: `mise run test --filter EXPORT-09`._
  _Greens: EXPORT-09._
- **M7-10a** _(Behavior)_ — Give subscribers independent buffers and leases.
  _Depends: M7-09a, M7-09b, M7-09c._
  _Verify: `mise run test --filter EXPORT-05`._
  _Greens: EXPORT-05._
- **M7-10b** _(Behavior)_ — Release only the cancelled subscriber's lease.
  _Depends: M7-10a._
  _Verify: `mise run test --filter EXPORT-06`._
  _Greens: EXPORT-06._
- **M7-10c** _(Behavior)_ — Hold a `whileObserved` cog across any number of
  grace periods while one subscription lives.
  _Depends: M7-10b._
  _Verify: `mise run test --filter EXPORT-15`._
  _Greens: EXPORT-15._
- **M7-11a** _(Behavior)_ — Offer no export value when derived recomputation
  lands equal.
  _Depends: M7-08._
  _Verify: `mise run test --filter EXPORT-14`._
  _Greens: EXPORT-14._
- **M7-11b** _(Behavior)_ — Offer export buffers before reactions in flush
  step 4.
  _Depends: M7-08._
  _Verify: `mise run test --filter REACT-20`._
  _Greens: REACT-20._
- **M7-12** _(Behavior)_ — Validate the view-scoped Weather `.task` loop and
  lease release on disappearance.
  _Depends: M7-10b._
  _Verify: Weather integration test filtered to EXPORT-07._
  _Greens: EXPORT-07._
- **M7-13a** _(Behavior)_ — Add iOS 26 key-path tracking with newest
  post-mutation values and property granularity.
  _Depends: M6-12b._
  _Verify: simulator tests for EXPORT-08 and EXPORT-10._
  _Greens: EXPORT-08, EXPORT-10._
- **M7-13b** _(Behavior)_ — Verify allowed coalescing at iOS 26 observation
  suspension boundaries.
  _Depends: M7-13a._
  _Verify: simulator test filtered to EXPORT-12._
  _Greens: EXPORT-12._
- **M7-14a** _(Infrastructure)_ — Implement the pre-iOS-26
  `withObservationTracking` re-arm shim.
  _Depends: M7-13a._
  _Verify: host shim tests around mutation and re-arm transitions._
- **M7-14b** _(Behavior)_ — Expose deterministic re-arm acknowledgement and
  document the disarmed window.
  _Depends: M7-14a._
  _Verify: `mise run test --filter EXPORT-11`._
  _Greens: EXPORT-11._
- **M7-14c** _(Infrastructure)_ — Extend the available pinned floor job with
  the pre-iOS-26 tracking scenarios.
  _Depends: M7-14b._
  _Non-blocking: execute only when the M2 floor job is available._
  _Verify: nightly floor workflow run._
- **M7-15** _(Behavior)_ — Add closure-form external tracking with the same
  modern and legacy semantics.
  _Depends: M7-13b, M7-14b._
  _Verify: modern simulator and legacy host tests for EXPORT-13._
  _Greens: EXPORT-13._
- **M7-16a** _(Gate)_ — Run the complete behavior suite on the selected ref,
  edge, and core layouts after every M7 track converges.
  _Depends: M7-03b, M7-04, M7-05, M7-07b, M7-10c, M7-11a, M7-11b,
  M7-12, M7-15._
  _Verify: complete host, release, simulator, Weather, available floor, and
  compile-fail suites._
  _Greens: COUNT-11._
- **M7-16b** _(Gate)_ — Prepare the non-mutating 0.3.0 release candidate,
  including benchmarks, docs, and changelog.
  _Depends: M7-16a._
  _Verify: approved release checklist with immutable CI links._
- **M7-16c** _(Release)_ — Create and push the annotated `0.3.0` tag, only
  after the 0.2.0 chain has resolved — published, or closed with `M6-12a`'s
  recorded not-applicable outcome.
  _Depends: M6-12e, M7-16b._
  _Verify: remote tag resolves to the approved commit._
- **M7-16d** _(Gate)_ — Verify docs and exact 0.3.0 consumption.
  _Depends: M7-16c._
  _Verify: post-release docs and scratch build._
- **M7-16e** _(Release)_ — Publish the 0.3.0 GitHub Release.
  _Depends: M7-16d._
  _Verify: published GitHub Release points at the approved tag._
