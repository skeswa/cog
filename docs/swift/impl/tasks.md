# Cog for Swift: task breakdown

_August 10, 2026_

This file splits [plan.md](./plan.md) into tasks of half a day or less. It also
assigns every [scenario](./scenarios.md) to one task.

## Execution rules

- **Keep the plan, ledger, and issues in sync.** The plan owns milestone scope,
  exit rules, and releases. This file owns tasks, dependencies, commands, and
  scenario coverage. GitHub issues own live status and evidence. Update all
  affected records in the same change.
- **Half a day is the cap.** This includes tests, code, checks, and docs. Split
  larger work with letter suffixes such as `M1-07a` and `M1-07b`. A second
  split adds another letter. Retire the parent ID and never reuse it.
- **Task IDs are stable.** Never renumber or reuse an ID. New independent
  tasks go at the end of their milestone; splits inherit the parent's number.
- **Every task has one type.** A _Decision_ records a choice. _Infrastructure_
  enables later work but owns no scenario. _Behavior_ makes listed scenarios
  pass. A _Gate_ checks work but does not fix it. A _Release_ publishes one
  outside result.
- **List only direct dependencies.** A prior milestone blocks work only when
  its gate appears in `_Depends:_`. Independent tasks may run together, but
  changes to the same files must land in order. List order is only a guide.
- **Gates cover all milestone behavior.** Only a task with an explicit
  `_Non-blocking:_` rule may sit outside the gate.
- **Verification is part of the task.** `_Verify:_` gives the exact command or
  review record. Test names include scenario IDs. Always use the mise wrappers
  for filters because they fail when a filter matches no test. The ledger
  checker makes each filter match the task's exact `_Greens:_` set and proof
  mode. Exit tests run in debug and release. Compile-fail, lint, simulator,
  floor, benchmark, and suite proofs use their named commands.
- **_Greens:_ owns coverage.** Every listed clause must be tested and passing.
  Each scenario appears on exactly one `_Greens:_` line. Only suite and
  release-configuration scenarios may belong to gates. Infrastructure and
  decision tasks have no `_Greens:_` line.
- **No task ends red.** Record benchmark results or early limits in
  `impl/benchmarks.md` when the scenario first passes. If a gate finds a bug,
  add a small repair task, make the gate depend on it, and rerun the gate.
- **Release steps stay ordered.** A candidate gate comes before the tag.
  Tagging, deployment checks, and publication are separate tasks. Each release
  depends on the last release's final task, and every publication follows a
  gate. Patch releases use the same chain. Binary asset checks and exact
  consumer checks remain separate steps.

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
  `mise run test --filter HarnessSentinelInfrastructure`, and
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
- **M0-05a** _(Decision)_ — Settle the self-hosted runner topology for the
  Mac mini: the ephemeral Tart-VM orchestrator (Tartelet, ekiden, or
  Cilicon — or record persistent bare metal with scrub hygiene as the
  fallback), the pinned runner image with Xcode 26.x, the repo-specific
  runner labels, and the fork-PR routing through the approval-gated
  GitHub-hosted macOS lane. Record the topology in the README before the
  workflow is created.
  _Verify: recorded topology decision, pinned image/Xcode pair, and runner
  labels._
- **M0-05b** _(Infrastructure)_ — Create `swift-ci.yml` with
  concurrency-cancel; path filters for `Package.swift`, `Package.resolved`,
  `swift/**`, `.swift-format`, `mise.toml`, and the workflow itself; format;
  four cached host-test legs on the provisioned self-hosted runner; the
  same-repo fork guard, least-privilege `permissions:`,
  `persist-credentials: false`, and a timeout on every self-hosted job; and
  the approval-gated GitHub-hosted macOS lane for fork pull requests.
  _Depends: M0-02, M0-04, M0-13._
  _Verify: a same-repo pull-request run completes all format and host-test
  jobs on the self-hosted runner._
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
  one map row per declared milestone, the matching task-section link, only
  existing same-milestone task IDs, and every explicit `_Non-blocking:_` task
  named in its row.
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
- **M0-13** _(Infrastructure)_ — Provision the Mac mini per the recorded
  topology: install the orchestrator, build or pull the pinned Xcode 26.x
  runner image, register ephemeral single-use runners under the
  repo-specific label, and harden a dedicated non-admin runner user holding
  no personal credentials.
  _Depends: M0-05a._
  _Verify: a sentinel workflow run from a same-repo branch executes on the
  runner, and a second run starts from a fresh environment (or the recorded
  bare-metal scrub applies)._
- **M0-14** _(Infrastructure)_ — Record and verify the repository's Actions
  fork-security settings: approval required for workflow runs from all
  external contributors, required full-SHA action pins, and the read-only
  default `GITHUB_TOKEN`; document the exact `gh api` verification commands
  in the README.
  _Verify: the three `gh api` reads return the recorded values._
- **M0-15** _(Infrastructure)_ — Add the workflow-contract check as
  `mise run workflows:check` and a CI step: every self-hosted job carries
  the same-repo guard, a least-privilege `permissions:` block,
  `persist-credentials: false`, and a timeout; no workflow uses
  `pull_request_target`; and every action is pinned to a full-length commit
  SHA.
  _Depends: M0-05b, M0-09aa._
  _Verify: `mise run workflows:check` plus guard-removed, over-broad
  permissions, unpinned-action, and `pull_request_target` fixtures._
- **M0-10** _(Gate)_ — Close scaffolding with every local command and CI job
  green on the stub.
  _Depends: M0-05c, M0-06, M0-08, M0-09b, M0-12, M0-14, M0-15._
  _Verify: `mise run fmt:check`, `mise run tasks:check`,
  `mise run test:matrix`, `mise run test:release`, and
  `mise run test:compilefail`._

## M1 tasks

_Plan scope and exit: [M1: Simple correctness core](./plan.md#plan-m1)._

- **M1-01a** _(Infrastructure)_ — Add final-class descriptors, stable
  `ObjectIdentifier` identity, human labels, and `Cog<T>.Manual` value references.
  _Depends: M0-10._
  _Verify: `mise run test --filter DescriptorInfrastructure`._
- **M1-34a** _(Decision)_ — Settle production-install and testing-factory
  helper spellings before either helper or its call sites exist; record the
  choice in §10 and the Swift README snapshot.
  _Depends: M0-10._
  _Verify: recorded decision, API sketch, and call-site vocabulary search._
- **M1-01b** _(Behavior)_ — Add descriptor-plus-key state storage, the
  `CogTesting` isolated-context factory, and untracked manual reads.
  _Depends: M1-01a, M1-34a._
  _Verify: `mise run test --filter DECL-01`._
  _Greens: DECL-01._
- **M1-01ca** _(Infrastructure)_ — Give testing contexts an injected clock
  protocol from day one.
  _Depends: M1-01b._
  _Verify: `mise run test --filter CogTestingClockInfrastructure`._
- **M1-01cb** _(Infrastructure)_ — Add deterministic MainActor cleanup
  acknowledgement primitives to `CogTesting` without exposing graph storage.
  _Depends: M1-01b._
  _Verify: `mise run test --filter CogTestingAcknowledgementInfrastructure`._
- **M1-02** _(Behavior)_ — Add `CogBox<Value, Key>.Manual`, constant and closure starting
  values, allocation-free `box[key]` value references, and per-key state identity.
  _Depends: M1-01b._
  _Verify: `mise run test --filter 'DECL-02|DECL-03|DECL-04'`._
  _Greens: DECL-02, DECL-03, DECL-04._
- **M1-03** _(Behavior)_ — Add `.readOnly`; verify reads and the rejected
  writer subscript fixture.
  _Depends: M1-02._
  _Verify: `mise run test --filter DECL-05` and `mise run test:compilefail`._
  _Greens: DECL-05, DECL-06._
- **M1-04aa** _(Infrastructure)_ — Add idle, accumulating, and flushing
  phases, default/custom turn-name capture, unforgeable turn IDs, and
  keyless pending/current storage.
  _Depends: M1-01b._
  _Verify: `mise run test --filter TurnStateInfrastructure`._
- **M1-04ab** _(Behavior)_ — Add keyless staging, writer read-back, flush on
  the outer turn boundary, and completed-turn normal reads during accumulation.
  _Depends: M1-04aa._
  _Verify: `mise run test --filter 'READ-01|TURN-01|TURN-03|TURN-04'`._
  _Greens: READ-01, TURN-01, TURN-03, TURN-04._
- **M1-04b** _(Behavior)_ — Add repeated and keyed staging semantics.
  _Depends: M1-02, M1-04ab._
  _Verify: `mise run test --filter 'TURN-02|TURN-14'`._
  _Greens: TURN-02, TURN-14._
- **M1-05a** _(Behavior)_ — Add keyless automatic cogs, tracked `c[...]`, lazy
  first computation, and caching.
  _Depends: M1-04ab._
  _Verify: `mise run test --filter 'DECL-07|DECL-09|READ-02'`._
  _Greens: DECL-07, DECL-09, READ-02._
- **M1-05b** _(Behavior)_ — Add automatic boxes and lexical keyed capture.
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
  from the newest published source value.
  _Depends: M1-06aa._
  _Verify: `mise run test --filter GRAPH-01`._
  _Greens: GRAPH-01._
- **M1-06b** _(Behavior)_ — Add multi-parent checking so multi-source turns
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
- **M1-07b** _(Behavior)_ — Equality-gate automatic recomputation and stop or
  continue downstream waves accordingly.
  _Depends: M1-06b, M1-07a._
  _Verify: `mise run test --filter 'GRAPH-05|GRAPH-06'`._
  _Greens: GRAPH-05, GRAPH-06._
- **M1-08a** _(Behavior)_ — Keep cold cogs dirty without recomputing and catch
  them up once after any number of turns.
  _Depends: M1-06ab._
  _Verify: `mise run test --filter 'GRAPH-07|GRAPH-08'`._
  _Greens: GRAPH-07, GRAPH-08._
- **M1-08b** _(Behavior)_ — Add subscription-free one-shot `cogs.peek` that
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
  value-reference indirection.
  _Depends: M1-04b, M1-05b, M1-09a._
  _Verify: `mise run test --filter 'GRAPH-11|GRAPH-12'`._
  _Greens: GRAPH-11, GRAPH-12._
- **M1-09c** _(Behavior)_ — Add `c.peek` reads that skip edges but settle.
  _Depends: M1-08b, M1-09a._
  _Verify: `mise run test --filter READ-06`._
  _Greens: READ-06._
- **M1-10** _(Behavior)_ — Add `c.curr`, including the no-previous first run.
  _Depends: M1-06ab._
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
  _Verify: internal self, multi-state, and keyed cycle probes._
- **M1-15c** _(Behavior)_ — Add conditional/keyed cycle reporting and the
  narrow `CogTesting` diagnostic seam.
  _Depends: M1-15b._
  _Verify: `mise run test --filter 'CYCLE-03|CYCLE-04'`._
  _Greens: CYCLE-03, CYCLE-04._
- **M1-15d** _(Behavior)_ — Prove self and multi-state cycle failure in debug
  and release with exit tests.
  _Depends: M1-15c._
  _Verify: `mise run test --filter 'CYCLE-01|CYCLE-02'` and
  `mise run test:release --filter 'CYCLE-01|CYCLE-02'`._
  _Greens: CYCLE-01, CYCLE-02._
- **M1-15ea** _(Behavior)_ — Reject a turn throughout automatic computation,
  including custom equality, before its body or attempted graph mutation.
  _Depends: M1-07b, M1-15b._
  _Verify: `mise run test --filter CYCLE-06` and
  `mise run test:release --filter CYCLE-06`._
  _Greens: CYCLE-06._
- **M1-31b** _(Behavior)_ — Show explicit and `fileID:line` labels in both
  cycle diagnostics and debug history.
  _Depends: M1-15c, M1-31a._
  _Verify: `mise run test --filter 'DECL-10|DECL-11'`._
  _Greens: DECL-10, DECL-11._
- **M1-35a** _(Infrastructure)_ — Add the `Mechanism` protocol with its
  defaulted `name`, the curated final-class `MechanismController` shell
  (registration entry points, untracked `peek`, and the `CogOps`
  conformance), the internal per-mechanism registration scope containers that
  retain their controller without letting it own the runtime, and
  `Cogs.forTesting(mechanisms:)` operating each mechanism at creation.
  _Depends: M1-01b._
  _Verify: `mise run test --filter MechanismShellInfrastructure`._
- **M1-16a** _(Decision)_ — Settle when a reaction registered during a flush
  performs its initial tracking run; update §10, snapshot, scenarios, and
  tasks, using the `M1-16e*` branch for any new behavior tasks.
  _Depends: M1-13a._
  _Verify: recorded decision, final-gate dependency update, and
  `mise run tasks:check`._
- **M1-16b** _(Behavior)_ — Add immediate reaction registration through the
  mechanism controller, changed dependency wake-up, and unrelated-turn
  quietness.
  _Depends: M1-07b, M1-16a, M1-35a._
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
- **M1-16ea** _(Behavior)_ — Queue initial runs for reactions registered during
  a flush without re-entry, after already-scheduled reactions and before queued
  write-back turns.
  _Depends: M1-16c._
  _Verify: `mise run test --filter REACT-23`._
  _Greens: REACT-23._
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
- **M1-35b** _(Infrastructure)_ — Make internal registration handles and
  mechanism scopes cancel terminally and idempotently: cancelling a scope
  unregisters its reactions exactly once, a registration arriving at a
  cancelled scope is cancelled synchronously without retention, and no
  operation reopens a cancelled scope. (Replaces the retired public-token
  and effect-group tasks `M1-18a`, `M1-18b`, `M1-23b`, `M1-23c`, `M1-23da`,
  and `M1-22`, whose terminal semantics survive as these internal
  invariants.)
  _Depends: M1-16b._
  _Verify: `mise run test --filter ScopeCancellationInfrastructure`._
- **M1-19a** _(Behavior)_ — Give reactions a read-only controller and add its
  compile-fail write fixture.
  _Depends: M1-03, M1-16b._
  _Verify: `mise run test:compilefail`._
  _Greens: REACT-14._
- **M1-19b** _(Behavior)_ — Do not wake reactions for equal manual writes or
  equal automatic recomputation.
  _Depends: M1-16c._
  _Verify: `mise run test --filter 'REACT-21|REACT-22'`._
  _Greens: REACT-21, REACT-22._
- **M1-20a** _(Behavior)_ — Queue one op called by a reaction as a new turn.
  _Depends: M1-16d._
  _Verify: `mise run test --filter REACT-15`._
  _Greens: REACT-15._
- **M1-20b** _(Behavior)_ — Drain a chain of reaction write-backs one settled
  turn at a time.
  _Depends: M1-20a._
  _Verify: `mise run test --filter REACT-16`._
  _Greens: REACT-16._
- **M1-13b** _(Behavior)_ — Verify several turns queued during one flush
  complete in FIFO settle-notify-react order.
  _Depends: M1-20b._
  _Verify: `mise run test --filter TURN-08`._
  _Greens: TURN-08._
- **M1-21** _(Behavior)_ — Add the debug turn-chain warning, causal chain,
  deterministic diagnostic seam, and synchronous return to idle.
  _Depends: M1-20b, M1-31a._
  _Verify: `mise run test --filter REACT-17`._
  _Greens: REACT-17._
- **M1-31c** _(Behavior)_ — Record named watch runs in history under their
  mechanism's name.
  _Depends: M1-17, M1-31a._
  _Verify: `mise run test --filter HIST-05`._
  _Greens: HIST-05._
- **M1-36** _(Decision)_ — Adopt the mechanism redesign: bootstrap-only
  registration through `Cogs.bootstrapApp(mechanisms:)`, the curated
  controller with state-gated `whenever` scopes, ops shared through
  `CogOps`, and withdrawal of the public `run`/`watch`/`EffectGroup`/
  `ReactionToken` surface. Update §10, the snapshot, scenarios, and tasks.
  (This decision retired the completed public-token and effect-group tasks
  `M1-18a`, `M1-18b`, `M1-22`, `M1-23a`, `M1-23b`, `M1-23c`, `M1-23da`,
  `M1-24a`, `M1-24b`, `M1-25`, and `M1-26` along with the GROUP scenario
  family; the `M1-35*` and `M1-37*` tasks carry the replacement work.)
  _Depends: M1-16b._
  _Verify: recorded decision, final-gate dependency update, and
  `mise run tasks:check`._
- **M1-35c** _(Infrastructure)_ — Add `m.task(name:)` ownership inside
  mechanism scopes: a task belongs to the scope that started it, receives
  cancellation when that scope ends, and composes its name under the
  mechanism's.
  _Depends: M1-35b._
  _Verify: `mise run test --filter MechanismTaskInfrastructure`._
- **M1-37a** _(Behavior)_ — Operate bootstrap mechanisms synchronously in
  list order, settle operate-time writes before the factory returns, and
  expose an earlier mechanism's published values to a later mechanism's
  `operate`.
  _Depends: M1-16c._
  _Verify: `mise run test --filter 'MECH-01|MECH-02'`._
  _Greens: MECH-01, MECH-02._
- **M1-37b** _(Behavior)_ — Keep declared mechanisms inert until bootstrap
  lists them; a mechanism left off the list never runs.
  _Depends: M1-16b._
  _Verify: `mise run test --filter MECH-03`._
  _Greens: MECH-03._
- **M1-37c** _(Behavior)_ — Reject two same-named mechanisms in one
  bootstrap list with a clear error in debug and release.
  _Depends: M1-35a._
  _Verify: `mise run test --filter MECH-04` and
  `mise run test:release --filter MECH-04`._
  _Greens: MECH-04._
- **M1-37d** _(Behavior)_ — Derive the default mechanism name from the type
  name and compose watch and task names beneath it in debug history and task
  names.
  _Depends: M1-17, M1-31a, M1-35c._
  _Verify: `mise run test --filter MECH-05`._
  _Greens: MECH-05._
- **M1-37e** _(Behavior)_ — Drive the named mechanism hourly task with
  `CogTesting.TestClock` and record its turn in history while the app entry
  point retains only `Cogs`.
  _Depends: M1-01ca, M1-31a, M1-35c._
  _Verify: `mise run test --filter MECH-06`._
  _Greens: MECH-06._
- **M1-37f** _(Behavior)_ — Add the `whenever` gated scope: run the body
  immediately on a true gate, tear registrations and tasks down when the
  gate falls, and re-run the body fresh on the next rise.
  _Depends: M1-16c, M1-35c._
  _Verify: `mise run test --filter 'MECH-07|MECH-08'`._
  _Greens: MECH-07, MECH-08._
- **M1-37g** _(Behavior)_ — Cancel nested `whenever` scopes with their
  parent.
  _Depends: M1-37f._
  _Verify: `mise run test --filter MECH-09`._
  _Greens: MECH-09._
- **M1-37h** _(Behavior)_ — Acknowledge cross-executor context-deinit
  cleanup and verify mechanism registrations are gone and owned tasks are
  cancelled.
  _Depends: M1-01cb, M1-37f._
  _Verify: `mise run test --filter MECH-10`._
  _Greens: MECH-10._
- **M1-37i** _(Behavior)_ — Run the `forTesting` seeding closure before any
  `operate`, so `initial: .run` watches observe seeded values on
  registration.
  _Depends: M1-17, M1-30a._
  _Verify: `mise run test --filter MECH-12`._
  _Greens: MECH-12._
- **M1-37j** _(Behavior)_ — Share one `CogOps` op definition between
  `Cogs` and the mechanism controller, attributing the mechanism's call to
  its mechanism in history.
  _Depends: M1-31a, M1-35a._
  _Verify: `mise run test --filter MECH-13`._
  _Greens: MECH-13._
- **M1-37k** _(Behavior)_ — Reject direct reaction registration on the
  runtime at compile time; registration exists only on the controller.
  _Depends: M1-16b._
  _Verify: `mise run test:compilefail`._
  _Greens: MECH-14._
- **M1-37l** _(Behavior)_ — Retain each supplied mechanism value for its
  runtime's lifetime, then cancel its scope before releasing the value and
  any class-owned resource during context teardown.
  _Depends: M1-37h._
  _Verify: `mise run test --filter MECH-15`._
  _Greens: MECH-15._
- **M1-37m** _(Behavior)_ — Support delegate-driven work through a weak
  mechanism-controller callback on a retained class mechanism: hop a live
  callback to the MainActor and attribute its op, then prove a callback after
  context teardown is inert and does not retain the context.
  _Depends: M1-37j, M1-37l._
  _Verify: `mise run test --filter MECH-16`._
  _Greens: MECH-16._
- **M1-27a** _(Infrastructure)_ — Add descriptor lifetime policy storage with
  manual `.app` and synchronous automatic `.whileObserved` defaults.
  _Depends: M1-05b, M1-08a._
  _Verify: `mise run test --filter LifetimePolicyInfrastructure`._
- **M1-27b** _(Infrastructure)_ — Track registered reactions as external
  lifetime leases, including dependency retracking and cancellation.
  _Depends: M1-16c, M1-27a, M1-35b._
  _Verify: `mise run test --filter ReactionLeaseInfrastructure`._
- **M1-28a** _(Behavior)_ — Store the 30-second context grace default with a
  testing override, then release an unobserved automatic cog after injected
  grace and recreate it correctly.
  _Depends: M1-01ca, M1-27b._
  _Verify: `mise run test --filter 'LIFE-02|LIFE-03'`._
  _Greens: LIFE-02, LIFE-03._
- **M1-28b** _(Behavior)_ — Cancel pending automatic release and prove reaction
  leases suppress release.
  _Depends: M1-28a._
  _Verify: `mise run test --filter 'LIFE-04|LIFE-07'`._
  _Greens: LIFE-04, LIFE-07._
- **M1-28c** _(Behavior)_ — Preserve default manual state and reset opted-in
  manual state to its initial value after release.
  _Depends: M1-28a._
  _Verify: `mise run test --filter 'LIFE-01|LIFE-05'`._
  _Greens: LIFE-01, LIFE-05._
- **M1-28d** _(Behavior)_ — Prove internal graph edges never act as leases.
  _Depends: M1-28a._
  _Verify: `mise run test --filter LIFE-09`._
  _Greens: LIFE-09._
- **M1-29a** _(Behavior)_ — Install one production context shared app-wide.
  _Depends: M1-04ab._
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
- **M1-30a** _(Behavior)_ — Add debug-only manual-source `seed` through
  `CogTesting` and dirty propagation without a turn.
  _Depends: M1-07a, M1-09a._
  _Verify: `mise run test --filter 'SEED-01|SEED-03'`._
  _Greens: SEED-01, SEED-03._
- **M1-30b** _(Behavior)_ — Prove seed is quiet for history and reactions and
  run the §6.6 alert story verbatim.
  _Depends: M1-16c, M1-30a, M1-31a._
  _Verify: `mise run test --filter 'SEED-02|SEED-04'`._
  _Greens: SEED-02, SEED-04._
- **M1-30c** _(Behavior)_ — Reject seeding an automatic cog at compile time.
  _Depends: M1-30a._
  _Verify: `mise run test:compilefail`._
  _Greens: SEED-06._
- **M1-33a** _(Behavior)_ — Add the off-actor compile-fail fixture and prove
  non-`Sendable` MainActor values need no wrapper.
  _Depends: M1-05a._
  _Verify: `mise run test:compilefail` and
  `mise run test --filter ACTOR-03`._
  _Greens: ACTOR-02, ACTOR-03._
- **M1-33b** _(Behavior)_ — Prove selectors, turn bodies, and reactions run
  on the MainActor in every build-settings leg.
  _Depends: M1-16b, M1-33a._
  _Verify: `mise run test:matrix --filter ACTOR-01`._
  _Greens: ACTOR-01._
- **M1-33c** _(Gate)_ — Run the complete host-runnable M1 suite in all four
  build-settings legs.
  _Depends: M1-05c, M1-06c, M1-09c, M1-10, M1-11, M1-12b, M1-13b,
  M1-14, M1-15d, M1-15ea, M1-16ea, M1-19a, M1-19b, M1-21, M1-28b, M1-28c,
  M1-28d, M1-30b, M1-30c, M1-31b, M1-31c, M1-33b, M1-34b, M1-37a, M1-37b,
  M1-37c, M1-37d, M1-37e, M1-37g, M1-37i, M1-37k, M1-37m._
  _Verify: `mise run test:matrix` and `mise run test:compilefail`._
  _Greens: LEG-01._
- **M1-32** _(Gate)_ — Prove the completed M1 suite and every-build guards in
  release, including absent `CogTesting.seed` and zero-cost history.
  _Depends: M1-33c._
  _Verify: `mise run test:release` plus release API/build checks._
  _Greens: SEED-05, HIST-04, LEG-03._

## M2 tasks

_Plan scope and exit: [M2: SwiftUI boundary and Weather](./plan.md#plan-m2)._

- **M2-17a** _(Decision)_ — In the smallest tracked-view prototype, compare an
  explicit tracked method, a subscript, and callable value references before
  boundary call sites multiply.
  _Depends: M1-32._
  _Verify: decision rationale in §10 and the Swift README snapshot._
- **M2-17b** _(Infrastructure)_ — Apply the settled subscript and `peek`
  spellings and record them in §10 and the Swift README snapshot.
  _Depends: M2-17a._
  _Verify: API call-site search plus `mise run fmt:check`._
- **M2-01** _(Infrastructure)_ — Add registrar-backed boundary objects,
  one phantom key path, lazy per-state storage, and change-only mutation.
  _Depends: M2-17b._
  _Verify: focused registrar infrastructure tests._
- **M2-02aa** _(Behavior)_ — Add the `\.cogs` environment key and prove each
  consuming view resolves the installed app context without an intermediate
  view accepting or forwarding it.
  _Depends: M2-01._
  _Verify: `mise run test --filter UI-06`._
  _Greens: UI-06._
- **M2-02ab** _(Behavior)_ — Add tracked view reads with changed-value and
  unrelated-write behavior.
  _Depends: M2-02aa._
  _Verify: `mise run test --filter 'UI-01|UI-02'`._
  _Greens: UI-01, UI-02._
- **M2-02b** _(Behavior)_ — Prove only UI-read states receive boundary objects
  and interior states never do.
  _Depends: M2-02ab._
  _Verify: `mise run test --filter UI-05`._
  _Greens: UI-05._
- **M2-03** _(Behavior)_ — Notice only readers of the written keyed value.
  _Depends: M2-02ab._
  _Verify: `mise run test --filter UI-03`._
  _Greens: UI-03._
- **M2-04** _(Behavior)_ — Suppress UI notices for equal manual writes and
  equal automatic recomputation.
  _Depends: M2-02ab._
  _Verify: `mise run test --filter UI-04`._
  _Greens: UI-04._
- **M2-05** _(Behavior)_ — Prove an application-owned SwiftUI binding can
  delegate to domain ops, with compact single-source turns and immediate
  read-back; add no Cog binding helper.
  _Depends: M2-02ab._
  _Verify: `mise run test --filter UI-07`._
  _Greens: UI-07._
- **M2-06** _(Behavior)_ — Keep one-shot reads in view bodies unsubscribed.
  _Depends: M2-02ab._
  _Verify: `mise run test --filter UI-09`._
  _Greens: UI-09._
- **M2-07** _(Decision)_ — Record that public Observation cannot distinguish
  a valid automatically tracked UI subscript read from one with no consumer;
  keep the direct spelling, require `peek` in actions, and defer the warning.
  _Depends: M2-02ab._
  _Verify: documentation alignment plus `mise run tasks:check`._
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
- **M2-10** _(Behavior)_ — Pin a state after its first UI read for the app
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
- **M2-14a** _(Infrastructure)_ — Create Weather's Xcode workspace with a
  local-path dependency on Cog, then build its state layer with per-ZIP
  sources, `fileprivate` access, automatic values, and ops.
  _Depends: M2-05, M2-10._
  _Verify: Weather scheme builds after the state layer change._
- **M2-14b** _(Infrastructure)_ — Register Weather's mechanism at bootstrap:
  its nice-weather reaction and injected-clock hourly task, with any shorter
  lifetime expressed as a `whenever` gate.
  _Depends: M2-14a._
  _Verify: Weather scheme builds and its mechanism tests pass._
- **M2-15** _(Infrastructure)_ — Build Weather cards, bindings, and per-ZIP
  tracked reads.
  _Depends: M2-14a._
  _Verify: Weather scheme builds and launches in the simulator._
- **M2-16** _(Gate)_ — Verify Weather with deterministic render counters: one
  ZIP invalidates one card, pairs never tear, and notices precede reactions.
  _Depends: M2-03, M2-08, M2-09, M2-14b, M2-15._
  _Verify: Weather integration tests using counters, never log scraping._
- **M2-13b** _(Infrastructure)_ — Add the Weather build CI job only after the
  example exists.
  _Depends: M2-15._
  _Verify: the Weather build job passes in CI._
- **M2-18a** _(Decision)_ — Time-box investigation of pinned iOS 17 runtime
  installation into the self-hosted runner's pinned image; record exact
  mechanics and whether that runtime can be kept reliably available. The
  floor requirement is retired unless a future task records a reliable pinned
  runtime.
  _Verify: reproducible install command or documented non-blocking fallback._
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

- **M3-01** _(Behavior)_ — Add `CogStatus` with a three-valued `kind`, total
  `value`, `hasSucceeded`, and loading semantics, with exhaustive status
  accessor tests.
  _Depends: M2-20._
  _Verify: `mise run test --filter ASYNC-04`._
  _Greens: ASYNC-04._
- **M3-02** _(Behavior)_ — On first tracked read, start work, publish pending
  as a turn, and expose no initial status case.
  _Depends: M3-01._
  _Verify: `mise run test --filter ASYNC-01`._
  _Greens: ASYNC-01._
- **M3-03a** _(Behavior)_ — Publish success and failure as distinct named
  turns observed by watchers.
  _Depends: M3-02._
  _Verify: `mise run test --filter ASYNC-02`._
  _Greens: ASYNC-02._
- **M3-03b** _(Behavior)_ — Preserve a successful optional `nil` through
  `value` plus `hasSucceeded`.
  _Depends: M3-03a._
  _Verify: `mise run test --filter ASYNC-03`._
  _Greens: ASYNC-03._
- **M3-03c** _(Behavior)_ — Record initial pending and failure as separate
  watcher/history turns with the resting default and no accepted success.
  _Depends: M3-03a._
  _Verify: `mise run test --filter ASYNC-18`._
  _Greens: ASYNC-18._
- **M3-04** _(Behavior)_ — Add the total value projection and suppress
  downstream change for equal reload results.
  _Depends: M3-03a._
  _Verify: `mise run test --filter ASYNC-20`._
  _Greens: ASYNC-20._
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
- **M3-07** _(Behavior)_ — Fetch and track `CogBox<Value, Key>.Async` status independently by key.
  _Depends: M3-05a._
  _Verify: `mise run test --filter ASYNC-12`._
  _Greens: ASYNC-12._
- **M3-08a** _(Decision)_ — Settle one-shot reads and refreshes of never-read
  async value references; update §10, snapshot, scenarios, and tasks before implementing
  refresh, using the `M3-08c*` branch for any additional behavior tasks.
  _Depends: M3-02._
  _Verify: recorded decision, any `M3-08c*` terminal added to M3-11, and
  `mise run tasks:check`._
- **M3-08b** _(Behavior)_ — Refresh settled or in-flight latest work under
  the same replacement and generation rules, returning handles bound to their
  exact success, failure, supersession, or release outcome.
  _Depends: M3-05b, M3-08a._
  _Verify: `mise run test --filter 'ASYNC-10|ASYNC-21'`._
  _Greens: ASYNC-10, ASYNC-21._
- **M3-09** _(Behavior)_ — Cancel work and advance generation on release;
  recreate without accepting late results.
  _Depends: M3-05b._
  _Verify: `mise run test --filter 'ASYNC-13|ASYNC-14'`._
  _Greens: ASYNC-13, ASYNC-14._
- **M3-08ca** _(Behavior)_ — Start a never-read async state exactly once from
  one-shot `peek` or `refresh`, publish initial pending without a durable
  consumer, and apply renewable `whileObserved` grace and safe release.
  _Depends: M3-08b, M3-09._
  _Verify: `mise run test --filter 'ASYNC-22|ASYNC-23'`._
  _Greens: ASYNC-22, ASYNC-23._
- **M3-10a** _(Behavior)_ — Run work on the MainActor by default in every
  build-settings leg.
  _Depends: M3-02._
  _Verify: `mise run test:matrix --filter ASYNC-15`._
  _Greens: ASYNC-15._
- **M3-10b** _(Behavior)_ — Run `@concurrent` work off-main and publish its
  result on the MainActor under the generation check.
  _Depends: M3-05b, M3-10a._
  _Verify: `mise run test:matrix --filter ASYNC-16`._
  _Greens: ASYNC-16._
- **M3-10c** _(Behavior)_ — Expose descriptor-based internal task names
  through the narrow testing seam.
  _Depends: M3-02._
  _Verify: `mise run test --filter ASYNC-17`._
  _Greens: ASYNC-17._
- **M3-10d** _(Behavior)_ — Reject work selected from invalidated dependencies
  while an async state is unobserved inside its lifetime grace.
  _Depends: M3-06, M3-09._
  _Verify: `mise run test --filter ASYNC-24`._
  _Greens: ASYNC-24._
- **M3-10e** _(Behavior)_ — Release an unobserved `.latest` projection and its
  async dependency after one shared grace window.
  _Depends: M3-04, M3-09._
  _Verify: `mise run test --filter ASYNC-25`._
  _Greens: ASYNC-25._
- **M3-10f** _(Behavior)_ — Expose the documented keyed `.latest` projection
  with stable per-key identity and equal-value suppression.
  _Depends: M3-04, M3-07._
  _Verify: `mise run test --filter ASYNC-26`._
  _Greens: ASYNC-26._
- **M3-10g** _(Behavior)_ — Reject public refresh during selector computation
  with the turn-during-automatic-computation diagnostic in debug and release.
  _Depends: M3-08b._
  _Verify: `mise run test --filter ASYNC-27` and
  `mise run test:release --filter ASYNC-27`._
  _Greens: ASYNC-27._
- **M3-10h** _(Behavior)_ — Defer graph-owned system turns requested during
  automatic computation until the outermost settle path exits, while keeping
  first pending synchronously readable and preserving named turn order.
  _Depends: M3-04._
  _Verify: `mise run test --filter ASYNC-28`._
  _Greens: ASYNC-28._
- **M3-10i** _(Behavior)_ — Coalesce repeated one-shot async grace renewals to
  one outstanding sleeper per exact state while retaining the newest deadline
  and shared release-cascade behavior.
  _Depends: M3-08ca._
  _Verify: `mise run test --filter ASYNC-29`._
  _Greens: ASYNC-29._
- **M3-10j** _(Behavior)_ — Treat a one-shot synchronous automatic peek as
  transient demand: renew ordinary `whileObserved` grace without a durable
  lease or Observation boundary, then release and recreate the state after
  expiry.
  _Depends: M1-08b, M1-28a._
  _Verify: `mise run test --filter LIFE-10`._
  _Greens: LIFE-10._
- **M3-10k** _(Infrastructure)_ — Replace Weather's imperative request sources
  and async op with one keyed `CogBox<Value, Key>.Async`; render status and total values, and
  route initial, retry, and hourly demand through `refresh` with deterministic
  example tests.
  _Depends: M3-04, M3-07, M3-08b, M3-10b._
  _Verify: `mise run build:weather` and `mise run test:weather`._
- **M3-11** _(Gate)_ — Close the deterministic async slice in every host leg
  and release configuration, including the async Weather integration.
  _Depends: M3-03c, M3-05c, M3-10c, M3-10d, M3-10e, M3-10f, M3-10g,
  M3-10h, M3-10i, M3-10j, M3-10k._
  _Verify: `mise run test:matrix`, `mise run test:release`, and
  `mise run test:weather`._

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
  _Depends: M4-04c, M4-05a, M4-06, M4-07e, M4-08, M4-09, M4-10, M4-11,
  M4-12, M4-13, M4-14._
  _Verify: the complete 0.1.0 checklist with immutable CI links._
- **M4-05c** _(Release)_ — Create and push the bare annotated `0.1.0` tag.
  _Depends: M4-05b._
  _Verify: the remote tag resolves to the approved commit._
- **M4-05d** _(Gate)_ — Verify Pages and smoke-test exact 0.1.0
  consumption.
  _Depends: M4-15._
  _Verify: live DocC URL and scratch `exact: "0.1.0"` build._
- **M4-05e** _(Release)_ — Create the 0.1.0 GitHub Release from the verified
  changelog excerpt.
  _Depends: M4-05d._
  _Verify: published GitHub Release points at the approved tag._
- **M4-06** _(Behavior)_ — Complete and flatten `CogStatus` with `kind`, total
  `value`, `hasSucceeded`, `error`, and `isLoading`, documented and proven
  right in every lifecycle state.
  _Depends: M3-11._
  _Verify: `mise run test --filter ASYNC-30`._
  _Greens: ASYNC-30._
- **M4-07a** _(Decision)_ — Record the value-first async read model: total
  value reads over declaration defaults, the `status` lens on every read
  capability, and an explicit default at every declaration; land the §5.1 and §10
  amendments with the scenario and task deltas they require.
  _Depends: M3-11._
  _Verify: updated design ledger, scenario tree, and task graph pass
  `mise run tasks:check` and `mise run fmt:check`._
- **M4-07b** _(Behavior)_ — Store explicit declaration defaults, require
  `default:` for every value including `Optional`, and make every value
  spelling total.
  _Depends: M4-07a._
  _Verify: `mise run test --filter ASYNC-31` and `mise run test:compilefail`._
  _Greens: ASYNC-31, ASYNC-34._
- **M4-07c** _(Behavior)_ — Add the `status` lens to every read capability
  with value-spelling parity and field-level SwiftUI Observation, refusing
  synchronous state at compile time.
  _Depends: M4-07a._
  _Verify: `mise run test --filter ASYNC-32` and `mise run test:compilefail`._
  _Greens: ASYNC-32, ASYNC-33._
- **M4-07d** _(Infrastructure)_ — Flip async `c[...]`, `cogs[...]`, peek, and
  watch to the value projection, remove the public `.latest` projection, and
  respell the existing behavior suite to the value-first spellings.
  _Depends: M4-07b, M4-07c._
  _Verify: `mise run test`, `mise run test:compilefail`, and
  `mise run fmt:check`._
- **M4-07e** _(Infrastructure)_ — Adopt value-first reads and the `status`
  lens in the Weather example and its tests.
  _Depends: M4-07d._
  _Verify: `mise run build:weather` and `mise run test:weather`._
- **M4-08** _(Behavior)_ — Prove turn-boundary settlement and
  shortcut-diamond consistency: an automatic cog settled mid-turn computes
  from published values, and an uneven diamond settles once with no torn
  pair.
  _Depends: M3-11._
  _Verify: `mise run test --filter 'TURN-15|GRAPH-13'`._
  _Greens: TURN-15, GRAPH-13._
- **M4-09** _(Behavior)_ — Prove the keyed cycle release trap renders every
  key in its crash message, in debug and release.
  _Depends: M3-11._
  _Verify: `mise run test --filter CYCLE-07` and
  `mise run test:release --filter CYCLE-07`._
  _Greens: CYCLE-07._
- **M4-10** _(Behavior)_ — Prove the debug seed-misuse guard traps clearly
  from a turn body and from a selector.
  _Depends: M3-11._
  _Verify: `mise run test --filter SEED-08`._
  _Greens: SEED-08._
- **M4-11** _(Behavior)_ — Prove mid-flush gated-scope teardown, per-key
  automatic lifetime independence, whole-and-ordered queued-turn history, and
  per-render Observation retracking.
  _Depends: M3-11._
  _Verify: `mise run test --filter 'MECH-11|LIFE-11|HIST-07|UI-16'`._
  _Greens: MECH-11, LIFE-11, HIST-07, UI-16._
- **M4-12** _(Behavior)_ — Prove refresh-handle supersession by dependency
  change, consecutive-failure status turns, and honest `CancellationError`
  failures from uncancelled current runs.
  _Depends: M4-07d._
  _Verify: `mise run test --filter 'ASYNC-35|ASYNC-38|ASYNC-39'`._
  _Greens: ASYNC-35, ASYNC-38, ASYNC-39._
- **M4-13** _(Behavior)_ — Prove cooperative cancellation of replaced
  `@concurrent` work and per-key release independence for keyed async boxes.
  _Depends: M4-07d._
  _Verify: `mise run test --filter 'ASYNC-36|ASYNC-37'`._
  _Greens: ASYNC-36, ASYNC-37._
- **M4-14** _(Behavior)_ — Bound the nesting a cold first read may cause and
  fail with a clear error naming the chain, in debug and release, instead of
  exhausting the stack. A first read of a never-computed dependency computes
  it inline, because a state's dependency set is only known once its selector
  has run, so the iterative walk cannot flatten a chain it has not seen yet.
  Measured on a 2026-08-16 macOS host: about 1,360 stack bytes per cold link
  in release and 4,176 in debug, over an eleven-frame cycle per link, giving
  roughly 6,100 links on an 8 MiB main stack and roughly 770 in release — or
  240 in debug — on iOS's 1 MiB main stack. The bound is fixed rather than
  measured at runtime so the same graph fails the same way on every platform
  and configuration.
  _Depends: M1-11._
  _Verify: `mise run test --filter GRAPH-14` and
  `mise run test:release --filter GRAPH-14`._
  _Greens: GRAPH-14._
- **M4-15** _(Infrastructure)_ — Permit semantic-version tags to deploy
  through the `github-pages` environment. The first `0.1.0` tag workflow built
  and uploaded its DocC archive, but environment protection rejected the tag
  before the deploy job could start.
  _Depends: M4-05c._
  _Verify: the environment policy admits tag `0.1.0`, and rerunning the tag
  workflow completes its deploy job successfully._

## M5 tasks

_Plan scope and exit: [M5: Benchmark port](./plan.md#plan-m5)._

- **M5-01a** _(Infrastructure)_ — Scaffold `CogScenarios` graph builders,
  in-selector counters, expected counts, and value-reference layout parameterization.
  Start once a release candidate is approved. What makes the overlap safe is
  that the approved commit is immutable, not that a ref points at it yet, so
  tagging, Pages, and GitHub Release verification may all finish in parallel
  with M5.
  _Depends: M4-05b._
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
  6.3 transition and MainActor benchmark compatibility, and measure
  VM-versus-bare-metal noise on the mini; record the supported backends, any
  required isolation shim, and where benchmarks run.
  _Depends: M5-05a, M5-05ba._
  _Verify: checked-in allocator/isolation compatibility table and probe logs._
- **M5-05c** _(Infrastructure)_ — Make one MainActor benchmark build and run,
  adding the pinned benchmark dependency, selected allocator configuration,
  and only the isolation shim proven necessary by the compatibility probes.
  _Depends: M5-05bb._
  _Verify: one MainActor benchmark builds and runs in the pinned environment._
- **M5-06** _(Behavior)_ — Add zero-allocation steady-turn and `box[key]`
  value-reference creation benchmarks.
  _Depends: M5-05c, M5-02a, M5-04a._
  _Verify: benchmark filters for PERF-01 and PERF-06 report the malloc counts
  `impl/benchmarks.md` records, zero for PERF-06._
  _Greens: PERF-01, PERF-06._
- **M5-08a** _(Infrastructure)_ — Add pinned-environment baseline update and
  check commands with metadata recorded beside every baseline.
  _Depends: M5-06._
  _Verify: update then check the zero-allocation baseline unchanged._
- **M5-07a** _(Behavior)_ — Measure propagation ARC traffic and record the
  result and gate in `impl/benchmarks.md`.
  _Depends: M5-08a._
  _Verify: benchmark filter for PERF-02 plus recorded result._
  _Greens: PERF-02._
- **M5-07b** _(Behavior)_ — Measure 1,000-state peak memory, record its initial
  threshold, and turn the check green.
  _Depends: M5-08a._
  _Verify: benchmark filter for PERF-03 plus the `impl/benchmarks.md` threshold._
  _Greens: PERF-03._
- **M5-07c** _(Behavior)_ — Measure lazy boundary-object count.
  _Depends: M5-08a._
  _Verify: benchmark filter for PERF-04 reports exactly the UI-read count._
  _Greens: PERF-04._
- **M5-07d** _(Behavior)_ — Measure pinned-key notice traffic, record its
  initial threshold, and turn the check green.
  _Depends: M5-08a._
  _Verify: benchmark filter for PERF-07 plus the `impl/benchmarks.md` threshold._
  _Greens: PERF-07._
- **M5-08b** _(Infrastructure)_ — Add `mise run bench` and the non-gating
  `bench-build` CI job.
  _Depends: M5-07a, M5-07b, M5-07c, M5-07d._
  _Verify: local bench command and CI release build._
- **M5-09a** _(Infrastructure)_ — Put value-reference layout behind the
  temporary test and benchmark seam used to compare candidates; record inline
  `AnyHashable` as the baseline candidate.
  _Depends: M5-04b, M5-08b._
  _Verify: recorded selected-layout behavior and keyed benchmark baseline._
- **M5-09b** _(Infrastructure)_ — Implement the interned-token candidate.
  _Depends: M5-09a._
  _Verify: recorded interned-token behavior and benchmark result._
- **M5-09c** _(Infrastructure)_ — Implement the generic-keyed-value-reference candidate.
  _Depends: M5-09a._
  _Verify: recorded generic-keyed behavior and benchmark result._
- **M5-09d** _(Behavior)_ — Run every behavior scenario through M5 unchanged
  under all three value-reference layouts before selecting one.
  _Depends: M5-02b, M5-03a, M5-03b, M5-09b, M5-09c._
  _Verify: `mise run test` plus the three-candidate result recorded in
  `impl/benchmarks.md`._
  _Greens: COUNT-09._
- **M5-09e** _(Behavior)_ — Benchmark keyed diamonds and churn under every
  value-reference layout, record results, and settle the layout in `impl/benchmarks.md` and exploration §10.
  _Depends: M5-09d._
  _Verify: recorded comparison and selected-layout rationale._
  _Greens: PERF-08._
- **M5-11** _(Infrastructure)_ — Make the benchmark gate deterministic.
  `M5-08a` measured two intermittent failures on the pinned harness: the
  whole-scenario `kairo-diamond` benchmark crashes the runner roughly one run
  in six under full instrumentation, at about 2,200 mallocs per iteration,
  while 20,000 iterations of the same scenario run clean outside the harness;
  and `perf-06-value-reference` occasionally reports a malloc deviation
  against its zero ceiling, which upstream's process-global counting can
  explain and which a gate cannot tolerate. Diagnose both, then either fix
  them or bound them explicitly — a workload cap, a metric set, or an upstream
  issue with a recorded workaround. `M5-08a` filters the gated baseline to the
  `perf-` family as a stopgap; this task is what lets the filter narrow or
  widen on evidence rather than on convenience.
  _Depends: M5-08a._
  _Verify: thirty consecutive `mise run bench:baseline:check` runs pass, and
  the disposition of each failure mode is recorded in
  `swift/Benchmarks/README.md`._
- **M5-10** _(Gate)_ — Close M5 with scenario tests, benchmark build,
  baselines, records, and the selected value-reference layout green.
  _Depends: M4-05e, M5-09e, M5-11._
  _Verify: `mise run test:matrix`, `mise run bench`, and baseline check._

## M6 tasks

_Plan scope and exit: [M6: Data-oriented core](./plan.md#plan-m6)._

- **M6-01a** _(Infrastructure)_ — Add arena slot allocation, reuse,
  generations, and the scalar SoA column skeleton.
  _Depends: M5-10._
  _Verify: focused allocate, release, reuse, generation, and scalar-column
  tests._
- **M6-01b** _(Infrastructure)_ — Put the core and edge representations behind
  temporary internal selectors without changing the public API.
  _Depends: M6-01a._
  _Verify: recorded selector sentinel results for simple and arena/pool._
- **M6-02** _(Infrastructure)_ — Implement the shared linked edge pool as the
  first runnable candidate.
  _Depends: M6-01b._
  _Verify: edge add, reuse, removal, and churn tests._
- **M6-06** _(Infrastructure)_ — Add typed per-descriptor current and pending
  value columns over arena slots.
  _Depends: M6-01a._
  _Verify: typed read, stage, publish, and removal tests._
- **M6-07aa** _(Infrastructure)_ — Stage and publish manual values through the
  arena and push dirty flags over baseline edges with a reused explicit stack.
  _Depends: M6-02, M6-06._
  _Verify: `mise run test --filter ArenaDirtyPropagationInfrastructure`._
- **M6-07ab** _(Infrastructure)_ — Pull and settle chain, diamond, and broad
  graphs with versions and equality backdating. Collapse the cold first-read
  frame cycle `M4-14` measured while rewriting this walk: nine of its eleven
  frames per cold link are Cog's own, so removing the existential witness hop
  and the `recompute`/`run`/`tracking` layering raises the `M4-14` bound
  without changing its shape.
  _Depends: M6-07aa._
  _Verify: `mise run test --filter 'GRAPH-01|GRAPH-02|GRAPH-04|GRAPH-05'`._
- **M6-07ac** _(Infrastructure)_ — Recapture dynamic dependencies and reuse or
  remove baseline edges as dependency sets change.
  _Depends: M6-07ab._
  _Verify: `mise run test --filter 'GRAPH-09|GRAPH-10|GRAPH-11|COUNT-08'`._
- **M6-07b** _(Infrastructure)_ — Add arena computing marks and keyed cycle
  paths.
  _Depends: M6-07ac._
  _Verify: `mise run test --filter CYCLE`._
- **M6-03** _(Infrastructure)_ — Implement Reactively-style per-state prefix
  arrays behind the runnable edge seam.
  _Depends: M6-07ac._
  _Verify: recorded prefix-array behavior and benchmark result._
- **M6-04** _(Infrastructure)_ — Implement inline-plus-overflow behind the
  runnable edge seam.
  _Depends: M6-07ac._
  _Verify: recorded inline-plus-overflow behavior and benchmark result._
- **M6-05a** _(Gate)_ — Run the complete M5 scenario set under all three arena
  edge candidates. Candidate-specific repairs discovered here become separate
  tasks before this gate is retried.
  _Depends: M6-03, M6-04, M6-07b._
  _Verify: recorded complete M5 scenario run under all three candidates, plus
  `mise run test` on the selected shared pool._
- **M6-05b** _(Infrastructure)_ — Benchmark mostly-static and high-churn
  graphs under all correct edge candidates.
  _Depends: M6-05a._
  _Verify: pinned comparison result set._
- **M6-05c** _(Behavior)_ — Record the edge measurements and settle the
  layout in `impl/benchmarks.md` and exploration §10.
  _Depends: M6-05b._
  _Verify: recorded decision and selected-candidate rerun._
  _Greens: PERF-09._
- **M6-08a** _(Infrastructure)_ — Integrate lazy boundary creation with arena
  slots.
  _Depends: M6-05c._
  _Verify: `mise run test --filter 'UI-01|UI-02|UI-05'`._
- **M6-08b** _(Behavior)_ — Reuse released slots with new generations and
  catch stale access in debug.
  _Depends: M6-08a._
  _Verify: benchmark/test filter for PERF-05._
  _Greens: PERF-05._
- **M6-09** _(Infrastructure)_ — Integrate the debug ring buffer with zero
  release cost.
  _Depends: M6-05c._
  _Verify: `mise run test --filter HIST` plus the arena
  release symbol/build check._
- **M6-10aa** _(Infrastructure)_ — Pass production/testing bootstrap,
  descriptors, and manual-source behavior through the arena selector.
  _Depends: M6-05c._
  _Verify: `mise run test --filter 'ONE|DECL-0[1-5]'`._
- **M6-10ab** _(Infrastructure)_ — Pass writer staging, turn phases, and
  queued-turn behavior through the arena selector.
  _Depends: M6-10aa._
  _Verify: `mise run test --filter TURN`._
- **M6-10ba** _(Infrastructure)_ — Pass tracked, untracked, lazy, equal, and
  dynamically recaptured automatic reads, plus automatic declaration and
  laziness behavior, through the arena selector.
  _Depends: M6-10ab._
  _Verify: `mise run test --filter 'READ|GRAPH|DECL-0[7-9]'`._
- **M6-10bb** _(Infrastructure)_ — Pass public self, multi-state, conditional,
  keyed, and turn-during-automatic-computation failure behavior through the
  arena selector.
  _Depends: M6-10ba._
  _Verify: `mise run test --filter CYCLE` and
  `mise run test:release --filter CYCLE`._
- **M6-10ca** _(Infrastructure)_ — Pass reaction tracking, ordering,
  equality, watch, and cleanup behavior, plus MainActor confinement
  and non-`Sendable` values, through the arena selector.
  _Depends: M6-10ba._
  _Verify: `mise run test --filter 'REACT-(0[1-9]|14|2[1-3])|ACTOR-0[13]'`._
- **M6-10cb** _(Infrastructure)_ — Pass reaction write-back, FIFO draining,
  and the turn-chain diagnostic through the arena selector.
  _Depends: M6-10ca._
  _Verify: `mise run test --filter 'REACT-15|REACT-16|REACT-17'`._
- **M6-10cc** _(Infrastructure)_ — Keep the arena's debug-only quiescence
  probe out of release test compilation without publishing that diagnostic
  seam in production.
  _Depends: M6-10cb._
  _Verify: `mise run test --filter ArenaQuiescenceInfrastructure` and
  `mise run test:arena-configurations --filter ArenaSpecializationInfrastructure`._
- **M6-10d** _(Infrastructure)_ — Pass mechanism bootstrap, gated-scope
  cancellation, and task behavior through the arena core selector.
  _Depends: M6-10cb._
  _Verify: `mise run test --filter MECH`._
- **M6-10ea** _(Infrastructure)_ — Pass lifetime policies, external reaction
  leases, and UI pinning through arena lease counts.
  _Depends: M6-08b, M6-10ca._
  _Verify: `mise run test --filter
'ArenaLifetimePolicyInfrastructure|ArenaLeaseInfrastructure'`._
- **M6-10eb** _(Infrastructure)_ — Pass the complete lifetime behavior suite
  through arena grace, release, manual reset, and slot reuse.
  _Depends: M6-10ea._
  _Verify: `mise run test --filter LIFE`._
- **M6-10fa** _(Infrastructure)_ — Pass the M1 `CogTesting` debug-seed
  semantics, including the seed-misuse trap, through arena dirty propagation
  without turns, reactions, or history.
  _Depends: M6-09, M6-10cb._
  _Verify: `mise run test --filter 'SEED-0[1-4]|SEED-08'`,
  `mise run test:compilefail`, and the release absence check._
- **M6-10g** _(Infrastructure)_ — Pass UI boundary behavior and
  UI-before-reaction flush ordering through the arena core selector.
  _Depends: M6-08a, M6-10ca._
  _Verify: `mise run test --filter 'UI|REACT-19'` plus UIKit simulator
  scenarios._
- **M6-10fb** _(Infrastructure)_ — Pass bounded history, explicit and
  `fileID:line` labels, named effect runs, and UI notices through the arena
  ring buffer and diagnostics.
  _Depends: M6-09, M6-10cb, M6-10g._
  _Verify: `mise run test --filter 'HIST|DECL-1[01]'`
  plus the release zero-cost check._
- **M6-10fc** _(Infrastructure)_ — Prove seed stays silent at a real arena UI
  boundary.
  _Depends: M6-10fa, M6-10g._
  _Verify: `mise run test --filter SEED-07`._
- **M6-10ha** _(Infrastructure)_ — Pass async status creation, first work,
  results, projections, dependency capture, keys, isolation, and task naming
  through arena values.
  _Depends: M6-10ba._
  _Verify: `mise run test --filter 'ASYNC-(0[1-6]|1[125678]|20|26|3[01289])'`._
- **M6-10hb** _(Infrastructure)_ — Pass async replacement, refresh, stale
  generation rejection, previous-value carry, cold one-shot demand,
  non-reentrant system turns, bounded grace scheduling, and release/recreation
  through arena generations.
  _Depends: M6-10eb, M6-10ha._
  _Verify: `mise run test --filter
'ASYNC-(0[7-9]|10|1[349]|2[1-5]|2[7-9]|3[5-7])'`._
- **M6-10i** _(Behavior)_ — Run the complete behavior suite unchanged with
  the arena core selected in place of the simple one before changing the
  default. The recorded comparison is outcome-neutral: it proves the arena,
  it does not by itself adopt it.
  _Depends: M6-10bb, M6-10cc, M6-10d, M6-10fb, M6-10fc, M6-10hb._
  _Verify: `mise run test` and `mise run test:compilefail` plus the recorded
  pre-switch comparison._
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
  _Verify: complete pinned comparison result set in `impl/benchmarks.md`._
- **M6-11d** _(Behavior)_ — Select generous absolute thresholds and enable CI
  baseline gating, retaining the exact zero-malloc requirement.
  _Depends: M6-11c._
  _Verify: baseline check passes and a sentinel regression fails it._
  _Greens: PERF-10._
- **M6-12a** _(Decision)_ — Record what measurements settled and whether the
  arena replaces the simple core; update `impl/benchmarks.md`, exploration §10, and the snapshot.
  _Depends: M6-11d._
  _Verify: recorded core decision and release recommendation._
- **M6-13** _(Infrastructure)_ — Execute the recorded core decision. If
  `M6-12a` approves replacement, switch the default core to the arena and
  rerun the complete suite; otherwise keep the simple core as the default and
  record the arena's retained selector-only role. The default core never
  changes upstream of this task.
  _Depends: M6-12a._
  _Verify: `mise run test` with the default core matching the recorded decision._
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
- **M7-03b** _(Behavior)_ — Publish queued results in run order; the decision
  task owns failure scenarios in its reserved `M7-03c*` branch.
  _Depends: M7-03a._
  _Verify: `mise run test --filter POLICY-02`._
  _Greens: POLICY-02._
- **M7-03c** _(Behavior)_ — Continue a queue after a failed run while keeping
  failure publication and refresh outcomes bound to their exact runs.
  _Depends: M7-03b._
  _Verify: `mise run test --filter POLICY-06`._
  _Greens: POLICY-06._
- **M7-04** _(Behavior)_ — Finish current exhaust work and run one catch-up
  from the newest state.
  _Depends: M7-02._
  _Verify: `mise run test --filter POLICY-03`._
  _Greens: POLICY-03._
- **M7-05** _(Behavior)_ — Overlap merged runs and publish each result as its
  own turn.
  _Depends: M7-02._
  _Verify: `mise run test --filter POLICY-04`._
  _Greens: POLICY-04._
- **M7-06a** _(Behavior)_ — Start latest stream work, show loading before the
  first element, and publish each element under the settled equality rule;
  decision tasks add termination, failure, and equality behavior only in their
  reserved `M7-06b*`, `M7-06c*`, and `M7-06d*` branches.
  _Depends: M7-01b, M7-01c, M7-01d, M7-02._
  _Verify: `mise run test --filter 'STREAM-01|STREAM-02'`._
  _Greens: STREAM-01, STREAM-02._
- **M7-06b** _(Behavior)_ — Leave stream state untouched on natural end,
  including the empty-sequence pending state, until dependency change or
  explicit refresh starts a new generation.
  _Depends: M7-06a._
  _Verify: `mise run test --filter 'STREAM-05|STREAM-06'`._
  _Greens: STREAM-05, STREAM-06._
- **M7-06c** _(Behavior)_ — Publish errors from current streams while keeping
  Cog-initiated cancellation silent and refresh outcomes terminal.
  _Depends: M7-06a._
  _Verify: `mise run test --filter 'STREAM-0[7-9]'`._
  _Greens: STREAM-07, STREAM-08, STREAM-09._
- **M7-06d** _(Behavior)_ — Apply ordinary state equality to stream elements,
  including the conservative non-Equatable fallback.
  _Depends: M7-06a._
  _Verify: `mise run test --filter 'STREAM-1[01]'`._
  _Greens: STREAM-10, STREAM-11._
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
- **M7-11a** _(Behavior)_ — Offer no export value when automatic recomputation
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
- **M7-16a** _(Gate)_ — Run the complete behavior suite on the selected value-reference,
  edge, and core layouts after every M7 track converges.
  _Depends: M7-10c, M7-11a, M7-11b, M7-12, M7-15, M7-17._
  _Verify: complete host, release, simulator, Weather, available floor, and
  compile-fail suites._
  _Greens: COUNT-11._
- **M7-16b** _(Gate)_ — Prepare the non-mutating 0.3.0 release candidate,
  including benchmarks, docs, and changelog.
  _Depends: M7-18._
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
- **M7-17** _(Infrastructure)_ — Repair the arena async sidecar so ordered
  policies and latest streams preserve their selected scheduler and work shape
  instead of applying latest one-shot semantics to every declaration.
  _Depends: M7-03c, M7-04, M7-05, M7-06b, M7-06c, M7-06d, M7-07b._
  _Verify: `mise run test --filter
'POLICY-(01|02|03|04|06)|STREAM-(0[1-9]|1[01])'`._
- **M7-18** _(Infrastructure)_ — Prepare the 0.3.0 release notes and consumer
  documentation: changelog, current package pin, status snapshots, and a DocC
  guide connecting M7 streams, exports, and external Observation tracking.
  _Depends: M7-16a._
  _Verify: `mise run docs`, `mise run fmt:check`, and `mise run tasks:check`._

## M8 tasks

_Plan scope and exit: [M8: First-party lint tooling and 0.4.0](./plan.md#plan-m8)._

- **M8-01a** _(Decision)_ — Settle the `coglint` executable, package,
  plugin-product, artifact, and conditional distribution-repository names.
  _Depends: M4-05e._
  _Verify: accepted names recorded in lint.md §7 and the package-layout plan._
- **M8-01b** _(Decision)_ — Settle per-rule severities and whether a next-line
  suppression must carry a reason.
  _Depends: M4-05e._
  _Verify: accepted severity and suppression table recorded in lint.md._
- **M8-01c** _(Decision)_ — Settle the stable public URL shape for lint rule
  articles and any redirect contract it requires.
  _Depends: M4-05e._
  _Verify: one accepted URL per initial rule recorded in lint.md and the DocC plan._
- **M8-01d** _(Decision)_ — Pin the Swift tools, swift-syntax,
  swift-argument-parser, and supported macOS host architecture versions.
  _Depends: M4-05e._
  _Verify: compatibility builds and the accepted pins recorded in lint.md._
- **M8-01e** _(Decision)_ — Measure unused binary-target fetching in SwiftPM
  and Xcode, validate the asset-before-consumer release topology, and select
  the bounded Channel A or Channel B distribution path.
  _Depends: M8-01a, M8-01d._
  _Verify: reproducible resolve and fetch logs plus the selected channel and
  release ordering recorded in lint.md and plan.md._

- **M8-02a** _(Infrastructure)_ — Scaffold the isolated `swift/Lint` package,
  its source and test targets, and a root-manifest isolation assertion.
  _Depends: M8-01a, M8-01d._
  _Verify: nested package build and a dependency-graph check proving its
  source dependencies do not enter the root package._
- **M8-02b** _(Infrastructure)_ — Add the guarded `mise run test:lint`
  wrapper with test enumeration, scenario-filter matching, and authoritative
  executed-test counts; document the new command in both root instruction
  files and the root README.
  _Depends: M8-02a._
  _Verify: the wrapper's sentinel filter succeeds, an unmatched filter fails,
  `mise run fmt:check`, and synchronized command documentation._
- **M8-02c** _(Behavior)_ — Add the fixture harness for triggering and
  non-triggering inputs, exact positions, accepted evasions, and generated
  DocC example fragments.
  _Depends: M8-02b._
  _Verify: `mise run test:lint --filter LINT-02`._
  _Greens: LINT-02._
- **M8-02d** _(Behavior)_ — Implement deterministic CLI path discovery,
  diagnostic collection, Xcode output, help URLs, and clean/error exit status.
  _Depends: M8-01b, M8-01c, M8-02c._
  _Verify: `mise run test:lint --filter LINT-01`._
  _Greens: LINT-01._
- **M8-02e** _(Behavior)_ — Implement exact next-line suppression and the
  explicit production-versus-test target role.
  _Depends: M8-02d._
  _Verify: `mise run test:lint --filter LINT-03`._
  _Greens: LINT-03._

- **M8-03a** _(Behavior)_ — Implement the shared cog-declaration classifier,
  including normalized written types, initializers, projections, and its
  deliberate syntax-only evasions.
  _Depends: M8-02c._
  _Verify: `mise run test:lint --filter 'LINT-0[45]'`._
  _Greens: LINT-04, LINT-05._
- **M8-03b** _(Infrastructure)_ — Implement the shared view, graph-receiver,
  and app-entry classifiers, including bootstrap locals and documented
  cross-file misses.
  _Depends: M8-02c._
  _Verify: focused nested-package classifier tests._

- **M8-04** _(Behavior)_ — Implement `manual-cog-private` over the shared
  declaration classifier.
  _Depends: M8-02d, M8-03a._
  _Verify: `mise run test:lint --filter LINT-12`._
  _Greens: LINT-12._
- **M8-05** _(Behavior)_ — Implement `cog-declaration-suffix`, including
  shape plurality and qualifier placement.
  _Depends: M8-02d, M8-03a._
  _Verify: `mise run test:lint --filter LINT-06`._
  _Greens: LINT-06._
- **M8-06** _(Behavior)_ — Implement `no-cogs-in-view-init` over stored,
  initializer, and method parameter types.
  _Depends: M8-02d, M8-03b._
  _Verify: `mise run test:lint --filter LINT-07`._
  _Greens: LINT-07._
- **M8-07** _(Behavior)_ — Implement `primitives-only-in-ops`, including
  production graph receivers, `Cogs` extensions, legal `CogOps` nesting, and
  the explicit test-target exemption.
  _Depends: M8-02e, M8-03b._
  _Verify: `mise run test:lint --filter 'LINT-0[89]'`._
  _Greens: LINT-08, LINT-09._
- **M8-08** _(Behavior)_ — Implement `initial-state-in-mechanism`, including
  prohibited bootstrap-local work and the conforming initialization shapes.
  _Depends: M8-02d, M8-03b._
  _Verify: `mise run test:lint --filter 'LINT-1[01]'`._
  _Greens: LINT-10, LINT-11._
- **M8-09** _(Behavior)_ — Implement `no-multi-read-cogs-helper` with its
  exact lexical read count, exclusions, and accepted data-flow misses.
  _Depends: M8-02d, M8-03b._
  _Verify: `mise run test:lint --filter 'LINT-1[34]'`._
  _Greens: LINT-13, LINT-14._

- **M8-10a** _(Behavior)_ — Add the escaped GitHub workflow-command reporter
  over the shared finding model.
  _Depends: M8-02d._
  _Verify: `mise run test:lint --filter LINT-15`._
  _Greens: LINT-15._
- **M8-10b** _(Behavior)_ — Add the schema-valid SARIF reporter with exact
  regions and stable `helpUri` values.
  _Depends: M8-02d._
  _Verify: `mise run test:lint --filter LINT-16`._
  _Greens: LINT-16._

- **M8-11a** _(Behavior)_ — Build and checksum the macOS artifact bundle and
  prove exact host-variant selection from its metadata.
  _Depends: M8-04, M8-05, M8-06, M8-07, M8-08, M8-09, M8-10a, M8-10b._
  _Verify: artifact-bundle build and supported-host selection suite for LINT-19._
  _Greens: LINT-19._
- **M8-12a** _(Behavior)_ — Add the build-tool plugin over the local artifact
  bundle and exercise diagnostics and cache replay in scratch SwiftPM and
  Xcode consumers.
  _Depends: M8-11a._
  _Verify: scratch package and Xcode plugin suite for LINT-17._
  _Greens: LINT-17._
- **M8-12b** _(Behavior)_ — Add the command plugin over the same CLI,
  reporters, and target-role configuration.
  _Depends: M8-11a._
  _Verify: scratch command-plugin suite for LINT-18._
  _Greens: LINT-18._
- **M8-11b** _(Behavior)_ — Implement the selected Channel A root manifest or
  Channel B generated sibling manifest and prove its dependency and unused
  artifact behavior.
  _Depends: M8-01e, M8-12a, M8-12b._
  _Verify: ordinary-consumer resolve, fetch, and dependency-graph suite for LINT-20._
  _Greens: LINT-20._

- **M8-13a** _(Behavior)_ — Generate all six rule articles from fixtures in
  `Cog.docc` and verify their settled stable URLs.
  _Depends: M8-04, M8-05, M8-06, M8-07, M8-08, M8-09._
  _Verify: DocC archive and fixture-parity suite for LINT-22._
  _Greens: LINT-22._
- **M8-13b** _(Behavior)_ — Add `mise run lint:swift`, run the linter suite
  first, split production and test target roles, fix current library and
  Weather findings, and document the command in both root instruction files
  and the root README.
  _Depends: M8-04, M8-05, M8-06, M8-07, M8-08, M8-09._
  _Verify: repository dogfood suite for LINT-21 plus `mise run fmt:check`._
  _Greens: LINT-21._
- **M8-13c** _(Infrastructure)_ — Add the dogfood linter to Swift CI and
  extend the workflow-contract fixtures for its paths, permissions, and
  runner policy.
  _Depends: M8-10a, M8-13b._
  _Verify: `mise run workflows:check` and a green lint CI job._

- **M8-14** _(Infrastructure)_ — Make `lint:swift` portable to a clean
  checkout by naming only tracked target source roots. Keep missing-input
  validation strict: remove empty Xcode-created directory operands rather
  than teaching CogLint to ignore a misspelled path.
  _Depends: M8-13b._
  _Verify: `mise run lint:swift` from a clean Git archive and
  `mise run fmt:check`._

- **M8-15a** _(Gate)_ — Run the complete lint fixture, reporter, artifact,
  plugin, documentation, dogfood, and selected-distribution suite.
  _Depends: M8-11b, M8-13a, M8-13c, M8-14._
  _Verify: `mise run test:lint`, `mise run lint:swift`, `mise run docs`,
  `mise run workflows:check`, `mise run tasks:check`, and all scratch
  integration suites._
- **M8-15b** _(Gate)_ — Prepare the non-mutating 0.4.0 release candidate,
  including changelog, docs, immutable CI links, and the locally exercised
  checksummed artifact bundle.
  _Depends: M8-16, M8-17._
  _Verify: approved release checklist, artifact checksum, and immutable CI links._
- **M8-15c** _(Release)_ — Create and push the annotated `0.4.0` tag after the
  0.3.0 GitHub Release completes.
  _Depends: M7-16e, M8-15b._
  _Verify: remote tag resolves to the approved commit._
- **M8-15d** _(Release)_ — Publish the 0.4.0 GitHub Release with the approved
  checksummed lint artifact attached.
  _Depends: M8-15c._
  _Verify: published release points at the approved tag and exposes the named asset._
- **M8-15e** _(Gate)_ — Verify the 0.4.0 DocC deployment and download and
  checksum the published lint artifact.
  _Depends: M8-15d._
  _Verify: immutable docs URL, asset URL, and checksum evidence._
- **M8-15f** _(Release)_ — Under Channel B, publish the generated sibling
  distribution repository's matching 0.4.0 tag last; under Channel A, record
  the step not applicable.
  _Depends: M8-15e._
  _Verify: selected-channel record and, for Channel B, remote sibling tag and manifest._
- **M8-15g** _(Gate)_ — Prove exact 0.4.0 consumption through the selected
  distribution channel in a scratch iOS 17 app.
  _Depends: M8-18._
  _Verify: exact-consumer plugin build and documentation-link suite for LINT-23._
  _Greens: LINT-23._
- **M8-16** _(Infrastructure)_ — Prepare the 0.4.0 release notes and consumer
  lint documentation: changelog, current package pin, status snapshots, and
  a DocC setup guide for the selected Channel B plugins.
  _Depends: M8-15a._
  _Verify: `mise run docs`, `mise run test:lint-documentation`,
  `mise run fmt:check`, and `mise run tasks:check`._
- **M8-17** _(Infrastructure)_ — Build, exercise, checksum, and retain the
  0.4.0 candidate artifact under CI's pinned Xcode 26.6, with exact-source
  provenance and a downloadable immutable Actions artifact.
  _Depends: M8-15a._
  _Verify: `mise run workflows:check`, a green artifact job for the exact
  source SHA, and downloaded checksum/provenance matching the two successful
  host-selection probes._
- **M8-18** _(Infrastructure)_ — Correct the Channel B package identity in the
  consumer setup guide and permanently derive that spelling from its
  repository URL.
  _Depends: M8-15f._
  _Verify: `mise run test:lint-documentation`, `mise run fmt:check`, and
  `mise run tasks:check`._

## M9 tasks

_Plan scope and exit: [M9: Shared turn machinery and O(changed) notices](./plan.md#plan-m9)._

_Every task in this milestone keeps the public API and the recorded M6 core
disposition unchanged; a task that cannot is a plan change first._

- **M9-01** _(Decision)_ — Profile steady turns, settle walks, and pinned-key
  flushes on both cores. Record the costs, the chosen work, and the work left
  in issue #373. Keep a repeatable probe with the other benchmark tools.
  _Depends: M6-12b._
  _Verify: recorded `impl/optimization.md` profile entry with its environment, a
  runnable probe under `swift/Benchmarks/probes/`, and `mise run fmt:check`._
- **M9-02** _(Infrastructure)_ — Add one benchmark that compares the same turn
  with one pinned key and with 1,000 pinned keys.
  _Depends: M9-01._
  _Verify: `mise run bench --filter perf-11-pinned-key-slope-1 --filter
perf-11-pinned-key-slope-1000` reports both shapes, whose difference is the
  per-key cost. The harness matches a filter against a whole benchmark name, so
  both names are given._
- **M9-03** _(Infrastructure)_ — Check the arena's `changedAt` value before
  copying a boundary entry or fetching its descriptor record.
  _Depends: M9-02._
  _Verify: `mise run bench --filter perf-11-pinned-key-slope-1 --filter
perf-11-pinned-key-slope-1000` reports no ARC difference between the two shapes,
  and `mise run test --filter 'UI|SEED|HIST'` stays green._
- **M9-04** _(Infrastructure)_ — Give the simple core a changed-boundary queue.
  Deduplicate with one flag and keep creation-order notices. A boundary created
  during a flush joins the next flush.
  _Depends: M9-02._
  _Verify: `mise run test --filter 'UI|SEED|HIST'` and `mise run bench --filter
perf-11-pinned-key-slope-1 --filter perf-11-pinned-key-slope-1000`._
- **M9-05** _(Infrastructure)_ — Give the arena the same queue. Use a spare
  `CogArenaStateFlags` bit to remove duplicates while dirty propagation visits
  each row.
  _Depends: M9-03, M9-04._
  _Verify: `mise run test --filter 'UI|SEED|HIST'` and the arena slope
  benchmarks by exact name._
- **M9-06** _(Behavior)_ — Turn the flat pinned-key slope green on both cores
  and record the measurement and its gate in `impl/benchmarks.md`.
  _Depends: M9-05._
  _Verify: benchmark filter for the pinned-key slope on both cores reports no
  per-key traffic, plus the recorded `impl/benchmarks.md` result and threshold._
  _Greens: PERF-11._
- **M9-07** _(Infrastructure)_ — Add a non-escaping fast path for
  `turn(named:)` and `withTurn`, keeping an escaping overload for the
  queued-turn path that genuinely stores its body.
  _Depends: M9-01._
  _Verify: `mise run test --filter 'ONE|TURN'` and a steady-turn allocation
  count two lower than the recorded baseline._
- **M9-08** _(Infrastructure)_ — Replace each turn's `CogTurnID` and `CogTurn`
  with one reused buffer and an increasing integer token. Reuse the buffer for
  touched sources too. This removes three allocations and two actor-checked
  deinits.
  _Depends: M9-07._
  _Verify: `mise run test --filter 'TURN'`, the turn infrastructure suites
  through `mise run test --filter
'TurnQueueInfrastructure|TurnStateInfrastructure|TurnCompositionInfrastructure'`,
  and `mise run test:release`, which is where a generic-class deinit regression
  would appear._
- **M9-09** _(Infrastructure)_ — Reuse the invalidation and dependency arrays
  across turns. M9-08 owns the same fix for the touched-source array.
  _Depends: M9-01._
  _Verify: `mise run test --filter 'GRAPH|TURN'` and a steady-turn allocation
  count two lower than the recorded baseline._
- **M9-10** _(Behavior)_ — Turn the zero-allocation steady-turn machinery green
  and record the new count and its gate in `impl/benchmarks.md`.
  _Depends: M9-08, M9-09._
  _Verify: benchmark filter for the steady turn reports the recorded
  machinery-free malloc count, plus the recorded `impl/benchmarks.md` result._
  _Greens: PERF-12._
- **M9-11** _(Infrastructure)_ — Replace the settle walk's
  `state as? any DerivedCogSettleState` with a stored discriminator on
  `CogState`, so entering and exiting a node costs no conformance lookup, and
  drop the same cast from the boundary flush.
  _Depends: M9-01._
  _Verify: `mise run test --filter 'GRAPH|CYCLE'` and a deep-chain per-node
  cost below the recorded baseline._
- **M9-12** _(Infrastructure)_ — Cache each keyless descriptor's resolved state
  per context. This removes a hash and metadata request from each read. Keep a
  checked cast: `unsafeDowncast` saved about 5% but would turn a Cog bug into
  undefined behavior.
  _Depends: M9-01._
  _Verify: `mise run test --filter 'DECL|LIFE'`, `mise run test:release`, and a
  recorded steady-turn metadata share below the `M9-10` measurement._
- **M9-13** _(Infrastructure)_ — Remove dynamic actor checks from dependency
  recording and boundary notices. The profile measured them at one eighth of a
  steady turn.
  _Depends: M9-01._
  _Verify: `mise run test:matrix` and `mise run test:simulator`, since this
  changes how isolation is established rather than what it is._
- **M9-14** _(Infrastructure)_ — Merge the settle walk's enter and exit edge
  passes. Resolve each record and check each cycle once. Stop at clean rows.
  _Depends: M9-11._
  _Verify: `mise run test --filter 'GRAPH|CYCLE|COUNT'` and a deep-chain
  per-node cost below the recorded baseline._
- **M9-15** _(Behavior)_ — Turn the per-node settle cost green and record the
  measurement and its gate in `impl/benchmarks.md`.
  _Depends: M9-12, M9-13, M9-14._
  _Verify: `mise run bench --filter perf-13-deep-chain` reports the recorded
  per-turn allocation and ARC cost, `mise run bench:thresholds:check` holds its
  allocations at exactly zero, and `impl/benchmarks.md` records the per-node figures._
  _Greens: PERF-13._
- **M9-16** _(Gate)_ — Prove the runtime work changed no public behavior. Run
  the full isolation matrix, both arena modes, release, and simulator checks.
  _Depends: M9-06, M9-10, M9-15._
  _Verify: `mise run test:matrix`, `mise run test:arena-configurations`,
  `mise run test:release`,
  `mise run test:simulator`, `mise run test:compilefail`, and
  `mise run lint:swift` — which the first pass omitted, and which was the only
  check that had anything to say._
- **M9-20** _(Infrastructure)_ — Store boundary positions, not state objects,
  in the changed queue. Positions keep creation order and avoid retain traffic
  during append and sort.
  _Depends: M9-16._
  _Verify: `mise run test --filter 'UI|SEED|HIST'`, `mise run test:release`,
  and `mise run bench --filter perf-02-propagation --filter
perf-11-pinned-key-slope-1000` back at or below the pre-M9 propagation traffic
  with the flat slope intact._
- **M9-17** _(Behavior)_ — Compare the simple and arena cores again on steady,
  deep, broad, and unstable graphs after the shared runtime changes.
  _Depends: M9-20._
  _Verify: complete pinned comparison result set recorded in `impl/benchmarks.md`, taken
  in one session on the pinned benchmark host._
  _Greens: PERF-14._
- **M9-21** _(Infrastructure)_ — Sort and read the arena's changed-boundary
  queue in place. Returning it by value shared the buffer and made sorting
  allocate.
  _Depends: M9-17._
  _Verify: `mise run test --filter 'UI|SEED|HIST'`, `mise run test`, and
  `mise run bench --filter perf-01-steady-turn` at zero allocations._
- **M9-22** _(Infrastructure)_ — Remove dynamic exclusivity checks from scalar
  arena columns. MainActor access and trivial values make overlap impossible.
  Keep checks on user value columns because a value's `deinit` may run code.
  _Depends: M9-21._
  _Verify: `mise run test`, `mise run test:release`, and
  `mise run bench --filter perf-01-steady-turn` below the
  `M9-17` measurement at unchanged allocation counts._
- **M9-23** _(Infrastructure)_ — Cache each keyless descriptor's arena column
  and slot per context. Use an increasing context ID so reused memory addresses
  cannot match. Check the slot generation so stale cache entries fail safely.
  Keep the current keyed path.
  _Depends: M9-22._
  _Verify: `mise run test`, `mise run test --filter 'LIFE|SEED'`,
  `mise run test:release`, and `mise run bench --filter perf-01-steady-turn`
  below the `M9-22` measurement at unchanged allocations._
- **M9-24** _(Infrastructure)_ — Validate an arena generation once at each
  operation boundary instead of on almost every column access. Keep slot-based
  methods as checked wrappers, and measure again after M9-22.
  _Depends: M9-23._
  _Verify: `mise run test` and `mise run bench --filter perf-01-steady-turn`
  against the `M9-23` measurement, keeping the
  stale-token diagnostic on the side that can still move._
- **M9-25** _(Decision)_ — Measure build time and held memory for a 1,000-state
  graph on both cores. Use several paired runs because resident memory is
  sampled. Say when the samples cannot show a clear difference.
  _Depends: M9-24._
  _Verify: recorded `impl/benchmarks.md` entry with its environment, carrying paired
  runs rather than one, and `mise run fmt:check`._
- **M9-26** _(Decision)_ — Add graph construction to the M9-01 probe and find
  the call sites behind any build-time gap. Use sampler buckets when counters
  do not explain it.
  _Depends: M9-25._
  _Verify: recorded `impl/optimization.md` entry naming the buckets that moved, the
  `build` workload runnable from the probe's method document, and
  `mise run fmt:check`._
- **M9-27** _(Infrastructure)_ — Make the typed frontier the default. Remove
  the simple core and its private tests. Keep pool edges. Add the public,
  non-default `CompactArena` trait for smaller binaries. Make old layout
  selectors fail in the manifest.
  _Depends: M9-26._
  _Verify: `mise run test:arena-configurations`, `mise run test:matrix`,
  `mise run test:release`, `mise run test:compilefail`, and `mise run api:check`._
- **M9-18** _(Decision)_ — Record the new core choice, the remaining issue #373
  work, and whether to release. The specialized arena won every full-graph
  test. `CompactArena` serves apps that favor binary size.
  _Depends: M9-27._
  _Verify: recorded decision in `perf.md`, `impl/benchmarks.md`, and §10; the
  issue #373 disposition; and `mise run tasks:check`._
- **M9-19** _(Gate)_ — Close M9 on the recorded evidence: the benchmark gate
  green against the new thresholds, the documented decision, and the backlog
  issue updated to match what was scheduled.
  _Depends: M9-18._
  _Verify: `mise run bench:thresholds:check`,
  `mise run bench:thresholds:sentinel`, `mise run fmt:check`, and
  `mise run tasks:check`._

## M10 tasks

_Plan scope and exit: [M10: Storefront macrobenchmark](./plan.md#plan-m10)._

- **M10-01** _(Decision)_ — Set the Storefront workload's scale, declaration
  counts, async levels, and package boundary. Keep the scale configurable and
  tested; it represents one workload, not all apps. Put shared code in its own
  package so the iOS app does not load benchmark-only dependencies.
  _Verify: recorded `impl/benchmarks.md` entry naming the profile scale, the exact
  declaration census, and every adjustment from the original targets, plus
  `mise run tasks:check`._
- **M10-02** _(Infrastructure)_ — Build profiles, deterministic fixtures, four
  heavy kernels, the 16-step pricing ladder, domain ops, and the bootstrap
  mechanism. Add shape tests so a declaration-count change fails before it
  makes benchmark runs hard to compare.
  _Depends: M10-01._
  _Verify: `mise run test:storefront --filter StorefrontShapeTests` asserts the
  census, the profile scale, and the even category spread, and
  `mise run fmt:check`._
- **M10-03** _(Infrastructure)_ — Add the scripted service, 11-step trace,
  shadow model, and guarded test wrapper. Give each request a stable ID, wait
  for exact start sets, and release responses by name out of order. Keep a
  replaced request suspended so the trace controls its late completion.
  _Depends: M10-02._
  _Verify: `mise run test:storefront` runs the smoke trace end to end with every
  checkpoint holding and reports a nonzero authoritative executed count, and
  `mise run lint:swift`._
- **M10-04** _(Infrastructure)_ — Add six cuts: cold start, full session,
  settled actions, inventory burst, memory footprint, and compute-only control.
  Count allocations and ARC only in settled cuts. Run those first because the
  counter is process-wide. Keep footprint contexts alive, and fix the iteration
  count for resident-memory cuts.
  _Depends: M10-03._
  _Verify: `mise run bench --filter 'perf-15-storefront-.*'` registers and runs
  all six cuts, and `mise run test:lint` still proves the root package resolves
  no dependencies._
- **M10-05** _(Behavior)_ — Run the headless benchmark and record its first
  valid results. Before timing, each cut checks IDs, totals, accepted async
  generations, invalidation, and its checksum.
  _Depends: M10-04._
  _Verify: `mise run bench --filter 'perf-15-storefront-.*'` reports every cut,
  and `impl/benchmarks.md` records the measurements, the environment that produced
  them, and what the workload does not cover._
  _Greens: PERF-15._
- **M10-06** _(Infrastructure)_ — Add the SwiftUI app and UI-test target. Tests
  build in release with the debugger, coverage, screenshots, and runtime checks
  off. Views read Cog from the environment and call named ops. A launch flag
  hides benchmark controls in normal use.
  _Depends: M10-03._
  _Verify: `mise run build:storefront` and `mise run lint:swift`._
- **M10-07** _(Behavior)_ — Measure cold launch, settled scroll, scroll during
  an inventory burst, search, detail navigation, and cart actions. Reset app
  state before each sample and pin the device, orientation, locale, text size,
  fixture, and row height.
  _Depends: M10-06._
  _Verify: `mise run test:storefront-ui` executes the release suite on the
  pinned simulator with a nonzero executed count, and `impl/benchmarks.md` records the
  measured figures, their environment, and why a simulator hitch figure is a
  regression signal rather than a user-experience guarantee._
  _Greens: PERF-16._
- **M10-08** _(Behavior)_ — Measure the same Storefront session with the
  specialized and compact arenas in one session. This shows the compact
  binary-size tradeoff on an app-shaped graph.
  _Depends: M10-05._
  _Verify: `mise run bench --filter 'perf-15-storefront-.*'` and
  `mise run bench:compact --filter 'perf-15-storefront-.*'` taken in one session
  on the pinned benchmark host,
  with the paired comparison recorded in `impl/benchmarks.md`._
  _Greens: PERF-17._
- **M10-09** _(Decision)_ — Decide which cuts may get CI limits, what CI must
  confirm first, where cold-start time goes, and what work comes next. Add any
  needed scenarios and tasks.
  _Depends: M10-07, M10-08._
  _Verify: recorded decision in `impl/benchmarks.md` and the exploration §10 ledger, naming the
  threshold candidates and the follow-up work, plus `mise run tasks:check`._
- **M10-10** _(Gate)_ — Close M10 on the recorded evidence: the workload's
  suites green, the six cuts reporting under both arena configurations, the
  release UI suite executing on the pinned simulator, and the documents
  consistent.
  _Depends: M10-09._
  _Verify: `mise run test:storefront`, `mise run test:storefront-ui`,
  `mise run bench --filter 'perf-15-storefront-.*'`, `mise run lint:swift`,
  `mise run fmt:check`, and `mise run tasks:check`._
