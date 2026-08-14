# Cog for Swift: implementation plan

_August 10, 2026_

This plan turns the Swift spike ([exploration.md](../design/exploration.md)
§11, amended by [perf.md](../design/perf.md) §9) into milestones. It also fills in package
layout, formatting, tests, CI, and releases. The aim is to get Cog into iOS
apps soon without making a future Kotlin package awkward. The architecture is
settled elsewhere; its decision ledger stays in exploration §10. The companion
[scenarios.md](./scenarios.md) breaks these milestones into the test scenarios
that drive red-green implementation, and [tasks.md](./tasks.md) decomposes
every milestone into tasks of half an engineering day or less, assigning every
scenario to exactly one task.

## Plan decisions

- Layout: `Package.swift` is at the repo root because SwiftPM resolves remote
  packages only from a git root. There is no subdirectory option. All
  Swift sources live under `swift/` through custom target `path:` values (the
  firebase-ios-sdk pattern). A future `kotlin/` directory is a sibling that
  SwiftPM never sees. Local development uses jj colocated with git; SwiftPM,
  GitHub, and CI consume only the git side, so colocation changes nothing
  about this layout.
- Lint and format: use only the toolchain's `swift format`, both formatting and
  `lint --strict`. No SwiftLint.
- Order: async `.run` and `.latest` move ahead of the data-oriented core so
  0.1.0 includes the async state an app needs. Keep the rest of §11's order:
  benchmarks precede the data-oriented core, and public names remain open
  until after the swift-state-graph review.
- Testing posture (settled 2026-08-10): every test is fully optimistic, as
  fast and cheap as possible, and as implementation agnostic as possible.
  The normative statement is the "Testing constraints" section of
  [scenarios.md](./scenarios.md). The machinery it requires — an injected
  clock on testing contexts that drives `whileObserved` grace timing, named
  diagnostic seams exposed through `CogTesting`, Swift Testing exit tests
  for trap guarantees, and one batched expected-failure fixture pass for
  compile-fail checks — land in M0 and M1 below.
- Execution posture (settled 2026-08-10): implementation runs from the
  dependency graph in [tasks.md](./tasks.md), not from a flat backlog. Every
  executable task is a decision, infrastructure slice, red-green behavior
  slice, milestone gate, or single publication step; it is capped at half a
  day, names its immediate dependencies and closing verification, and ends
  green. Scenario credit belongs only to the task that can prove every clause
  against real infrastructure. Known compound work is split before execution,
  representation swaps integrate incrementally, and release preparation stays
  separate from remote publication.
- CI runners (settled 2026-08-10): macOS CI runs on a personal self-hosted
  Apple Silicon Mac mini; Linux jobs stay on GitHub-hosted `ubuntu`. Because
  the repo is public and its CI is pull-request-driven, fork security is
  layered rather than trigger-omitted (the dootdoot pattern of push-only
  self-hosted CI would leave pull requests with no macOS signal). The
  layers: every self-hosted job carries a same-repo guard
  (`github.repository == 'skeswa/cog'` and, on `pull_request` events,
  `github.event.pull_request.head.repo.full_name == github.repository`), so
  fork pull requests structurally never reach the mini and run instead in
  an approval-gated GitHub-hosted macOS lane; repository settings require
  approval for workflow runs from all external contributors, full-SHA
  action pins, and a read-only default `GITHUB_TOKEN` (applied 2026-08-10;
  `M0-14` records and verifies them); the runner topology is the
  persistent-bare-metal branch `M0-05a` settled on 2026-08-10 — one
  repository-scoped runner under the `cog-mini` label, pinned Xcode 26.6,
  and dootdoot-style scrub hygiene (workspace scrub hooks,
  `persist-credentials: false`, timeouts) in place of VM ephemerality, with
  Tart-based ephemeral VMs recorded as a deferred upgrade because no macOS
  orchestrator shipped a release in 2026. A dedicated non-admin runner user
  remains the target state but was declined on 2026-08-11, because the
  simulator lane needs an Aqua session and macOS allows one auto-login user;
  the accepted risk is recorded in the README. A
  committed workflow-contract check (`M0-15`) enforces the guards,
  permissions blocks, credential hygiene, and pins so the hardening cannot
  silently regress. The full topology record, including its revisit
  triggers, is the "macOS runner topology" section of the root README.
- Task bookkeeping (settled 2026-08-10): day-to-day execution bookkeeping —
  claiming, status, discussion, and closure — lives in the repository's
  GitHub issues, one issue per task with dependencies as native blocked-by
  relationships. The documents in this directory stay normative and never
  track live status; the "Task bookkeeping" section below is the contract.
- Ledger-integrity posture (settled 2026-08-10): four rules close the gaps a
  ledger review found. First, a task that mutates a default or publishes
  externally runs only downstream of the decision or gate that authorizes
  it — the M6 core-default switch is such a step (`M6-13`), so M6
  integration and measurement stay outcome-neutral behind the core selector
  and no measurement outcome can invalidate completed work. Second,
  externally visible releases form one dependency-ordered chain across
  milestones, patches included, so publications never interleave. Third, the
  task-ledger checker owns every derivable fact: the scenario census, exact
  filter expansion of behavior verifies, and completeness of the M6
  arena-integration filters, with exceptions named in the ledger rather than
  implied. Fourth, every scenario carries a proof mode (default `unit`);
  the checker matches greens ownership and verification commands to modes,
  and only suite- and release-configuration-mode scenarios may be greened by
  a gate.

Execution constraints from the design docs:

- One app-wide `Cogs`; guarded production construction; tests and previews
  get isolated contexts from the testing product.
- `commit` is the only write entry point: a compact scalar overload, a writer
  overload with turn IDs, three context phases, and the six-step flush order
  (§3.2).
- Lazy pull plus pushed dirty flags; CLEAN, CHECK, DIRTY with versions;
  equality gates; dependencies recaptured every run.
- `CogStatus.kind` begins publicly at `pending` with a total value and
  `hasSucceeded`; async
  selectors are synchronous and return `Work`; `.latest` is the default;
  streams are `.latest`-only.
- Public value references stay resilient (no `@frozen`) and never expose arena slots.
  Value reference, edge, and hash layouts wait for benchmarks (perf §4, §9).
- iOS 17 / Swift 6.2 floor; test with default MainActor isolation on and off
  and `NonisolatedNonsendingByDefault` on and off; no required macros.

## Target layout

```text
cog/                                  (git root = SwiftPM package root)
├── Package.swift                     # root manifest, swift-tools-version 6.2
├── LICENSE                           # missing today; required before 0.1.0
├── .swift-format
├── .github/workflows/
│   ├── swift-ci.yml                  # path-filtered for all Swift inputs
│   ├── swift-docs.yml                # DocC → GitHub Pages, on tag push
│   └── markdown.yml                  # oxfmt --check, ubuntu, *.md paths
├── tools/
│   └── check-task-ledger.mjs         # plan/task/scenario alignment + task DAG
├── docs/                             # living design and implementation docs
├── swift/
│   ├── Sources/
│   │   ├── Cog/                      # the library; Cog.docc/ catalog inside
│   │   ├── CogTesting/               # isolated-Cogs factory for tests/previews
│   │   └── CogScenarios/             # benchmark graphs + expected run counts,
│   │                                 #   shared by tests and benchmarks; exported
│   │                                 #   as non-API product _CogScenarios
│   ├── Tests/
│   │   ├── CogTests/                 # correctness suite (host-runnable)
│   │   ├── CogScenarioTests/         # run-count assertions over CogScenarios
│   │   └── CogBoundaryTests/         # Observation/SwiftUI boundary; UIKit files
│   │                                 #   behind #if canImport(UIKit)
│   ├── Benchmarks/                   # SEPARATE SwiftPM package so benchmark
│   │   └── Package.swift             #   deps never touch the shipped library
│   └── Examples/
│       └── Weather/                  # Xcode app project; local-path dep on root
└── kotlin/                           # future; never referenced by Package.swift
```

Products: `Cog`, `CogTesting` (depends on Cog), and `_CogScenarios` (for the
benchmark package only). Publish `seed` from `CogTesting`, only behind
`#if DEBUG` (§6.6).

Manifest choices:

- `platforms: [.iOS(.v17), .macOS(.v14)]`. macOS 14 is the Observation floor,
  so nearly all tests run host-side with `swift test`. Only UIKit
  checks, iOS 17 floor validation, and the example app need a simulator.
- Library settings: Swift 6 language mode,
  `.defaultIsolation(MainActor.self)` (the SE-0466 manifest API is why the
  tools version is 6.2), `NonisolatedNonsendingByDefault`, `ExistentialAny`,
  `MemberImportVisibility`, `InternalImportsByDefault`. Public declarations
  still state isolation explicitly (§7).
- Isolation matrix: library flags never change. The same test targets run in
  four legs, with their settings selected through env vars read by the
  manifest (`COG_TEST_ISOLATION=nonisolated`, `COG_TEST_NNBD=1`):
  {MainActor-default, nonisolated} × {NNBD on, off}. In M0, confirm env changes
  bust the manifest cache (fallback `--manifest-cache none`), and mirror each
  leg into a `.define()` so tests can assert which leg they run in.
- swift-docc-plugin is env-gated (`COG_DOCC=1`, set only by the docs
  workflow), so consumers resolve a zero-dependency package.

## Plan-to-task contract

The design docs remain normative for architecture and behavior. This plan owns
milestone intent, scope, exit criteria, and release boundaries. The task ledger
owns executable slices, immediate dependencies, exact verification commands,
and scenario ownership. Neither document silently overrides the other: a
change to a milestone boundary or exit updates its task graph in the same
change, and a task change that moves scope, changes a public command, or alters
a gate updates this plan in the same change.

Dependencies in the ledger are deliberately narrower than milestone order. A
prior milestone is a barrier only where the table below or an explicit
`_Depends:_` edge says it is. This permits independent work to start early
without weakening a milestone gate. Gates diagnose but never absorb repairs;
the smallest repair task is inserted before a failed gate is rerun.

| Plan milestone                   | Task ledger                     | Decisions before dependent work                                                    | Closing path                                                                                                                   |
| -------------------------------- | ------------------------------- | ---------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| M0: Scaffolding                  | [M0 tasks](./tasks.md#m0-tasks) | `M0-05a` runner topology                                                           | `M0-10`                                                                                                                        |
| M1: Simple correctness core      | [M1 tasks](./tasks.md#m1-tasks) | `M1-34a`, `M1-15a`, `M1-16a`, `M1-36`                                              | `M1-33c` host matrix, then `M1-32` release gate                                                                                |
| M2: SwiftUI and Weather          | [M2 tasks](./tasks.md#m2-tasks) | `M2-17a` read spelling; `M2-07` warning feasibility; `M2-18a` floor-runtime policy | `M2-16` Weather gate, then `M2-20`; iOS 17 floor coverage was explicitly retired when no reliable runtime was available        |
| M3: First async slice            | [M3 tasks](./tasks.md#m3-tasks) | `M3-08a` never-read async behavior                                                 | `M3-11`                                                                                                                        |
| M4: API review and 0.1.0         | [M4 tasks](./tasks.md#m4-tasks) | `M4-01a` public-name review; `M4-07a` value-first async reads                      | `M4-05b` candidate → `M4-05c` tag → `M4-05d` verification → `M4-05e` GitHub Release                                            |
| M5: Benchmark port               | [M5 tasks](./tasks.md#m5-tasks) | `M5-05ba` package/metric pins; `M5-05bb` allocator/isolation compatibility         | `M5-10`                                                                                                                        |
| M6: Data-oriented core           | [M6 tasks](./tasks.md#m6-tasks) | `M6-12a` core/release decision                                                     | `M6-05a` edge gate, then `M6-13` core default, then `M6-12b`; `M6-12c`, `M6-12d`, and `M6-12e` run only when 0.2.0 is approved |
| M7: Async completion and exports | [M7 tasks](./tasks.md#m7-tasks) | `M7-01a`, `M7-01b`, `M7-01c`, and `M7-01d` ordered/stream decisions                | `M7-16a` suite → `M7-16b` candidate → `M7-16c` tag → `M7-16d` verification → `M7-16e` GitHub Release; `M7-14c` is non-blocking |

## Task bookkeeping

Execution bookkeeping lives in the repository's GitHub issues. The documents
in this directory stay normative for what the work is; the issue tracker
carries the live state of doing it.

- One issue per task, titled `Mx-yy: <first sentence>`, labeled with its
  type (`decision`, `infrastructure`, `behavior`, `gate`, `release`, plus
  `non-blocking` where the ledger grants that policy), and assigned to its
  GitHub milestone. The M0–M7 milestones carry each plan-table row: the
  decisions that gate dependent work and the closing path.
- Every `_Depends:_` edge is encoded as a native GitHub blocked-by
  relationship, so the tracker's ready set — open issues with no open
  blockers — matches the ledger's dependency graph. Issues are created in
  dependency order so blockers always carry lower numbers.
- A per-milestone tracking issue holds the dependency-ordered checklist for
  progress at a glance.
- Claiming a task means assigning its issue. Closing a task requires posting
  the `_Verify:_` evidence — command output or immutable CI links — as a
  comment first. Gate issues close only after every blocking issue is
  closed, per the milestone's closing path.
- The ledger remains the source of truth. Any task change in
  [tasks.md](./tasks.md) — a new, split, or retired task, or changed
  dependencies, verification, or greens — updates the issue mirror in the
  same change: new issues for new tasks, blocked-by edits for dependency
  changes, a parent issue closed with a pointer to its split children, and
  retired tasks closed as not planned. `mise run tasks:check` validates only
  the documents; every issue title starts with its task ID precisely so the
  ledger and tracker can be diffed when drift is suspected.

## Milestones

<a id="plan-m0"></a>

### M0: Scaffolding

- Root `Package.swift` with stub `Cog` and `CogTesting` targets, test targets,
  and one sentinel test so every CI test leg proves it selected work. Add
  `LICENSE`.
- `.swift-format`: start from `swift format dump-configuration`, trim,
  two-space indent.
- `mise.toml`: split `fmt` into `fmt:md` and `fmt:swift`
  (`swift format --in-place --parallel --recursive swift Package.swift`)
  under `fmt` and `fmt:check` umbrellas; add `test`, `test:matrix` (loops
  the four legs), and `test:release` (`swift test -c release` on the default
  leg, so the guardrails that promise every-build behavior really run in a
  release configuration). The test wrappers list tests before every filtered
  run and fail if the expression selects none; raw `swift test --filter` is not
  a valid task-verification command because SwiftPM succeeds on an empty
  selection. Add `bench` in M5. mise cannot pin Xcode. The README documents
  the required version, and CI selects it with `xcode-select`.
- `swift-ci.yml`: concurrency-cancel; path filters for `Package.swift`,
  `Package.resolved`, `swift/**`, `.swift-format`, `mise.toml`, the workflow,
  the implementation plan, task/scenario ledgers, and their checker. M0
  includes only the jobs the stub can satisfy: `format` (swift format lint),
  `test-host` (four-leg matrix of `swift test --parallel`, `.build` cached per
  leg), and `test-release` (`swift test -c release` on the default leg — the
  leg where every-build guardrails such as the second-context guard, escaped
  writers, cycle detection, the absence of `CogTesting.seed`, and free debug
  history are
  proven outside debug). Add `test-simulator` in M2 and `bench-build` in M5.
  macOS jobs run on the self-hosted Mac mini under the labels and topology
  `M0-05a` records, with the pinned Xcode 26.x baked into the runner image;
  every self-hosted job carries the same-repo fork guard, a `permissions:`
  block no broader than `contents: read`, `persist-credentials: false` on
  checkout, and a timeout, and fork pull requests run only in the
  approval-gated GitHub-hosted macOS lane. `markdown.yml` runs oxfmt on
  GitHub-hosted ubuntu.
- Self-hosted runner: provision the Mac mini per the `M0-05a` topology
  decision — orchestrator, pinned Xcode image, ephemeral registration under
  a repo-specific label, and a hardened dedicated runner user (`M0-13`);
  record and verify the repository's Actions fork-security settings
  (`M0-14`); and add the workflow-contract check that fails CI if a
  hardening invariant regresses (`M0-15`).
- Compile-fail harness: a fixtures directory of expected-failure sources,
  compiled in one batched pass by a `test:compilefail` mise task and CI step
  that asserts each fixture fails with the expected diagnostic. The
  scenarios marked "(Proof: compile-fail.)" all run through this harness,
  never as per-test compiler invocations.
- Task-ledger checker: the pinned Node tool runs
  `tools/check-task-ledger.mjs`; `mise run tasks:check` verifies unique task
  IDs including recursive split suffixes; prefix-free executable IDs; exact,
  single-owner scenario coverage; existing and transitively minimal dependency
  IDs; and an acyclic task graph. It also verifies reachability of every
  behavior from its milestone gate except a task with a valid explicit
  `_Non-blocking:_` external-availability policy. Finally, it verifies that the
  plan-to-task table has exactly one row per milestone, links the matching task
  section, references only existing same-milestone task IDs, and names every
  explicit non-blocking exception. Two further check families (`M0-11`,
  `M0-12`) make the checker own every derivable fact: proof-mode
  consistency — each scenario's `(Proof: …)` mode, default `unit`, must
  match its owning task's type and verification commands, behavior filters
  must expand to exactly their unit- and exit-test greens, and the scenario
  census is derived, never hand-counted — and graph-order invariants —
  release tasks form one dependency-ordered chain, every release task
  follows a gate, and the M6 arena-integration filters cover every unit- and
  exit-test scenario owned by M1–M6 tasks except the exceptions the M6
  section names. Run it in CI with the other documentation checks.
- Update the root `README.md`, `docs/swift/README.md`, and `CLAUDE.md` plus
  `AGENTS.md` (kept in sync) with the new commands.

<a id="plan-m1"></a>

### M1: Simple correctness core (spike §11.1)

The class-state build. Correctness first; no perf tricks.

- Names: internal final-class descriptors (`ObjectIdentifier` identity;
  `name:` or `fileID:line` labels). Public value references `Cog<T>` and
  `ManualCog<T>`; boxes `CogBox` and `ManualCogBox`; inline `AnyHashable?`
  keys; allocation-free `box[key]`; the `.readOnly` projection.
- Cogs: states stored by descriptor plus key, created lazily; tracked
  subscripts, `peek`, and `curr` on the read capability; a MainActor-confined
  tracking slot. Non-tracking peeks still settle and return the latest value.
- Turns: `commit(_ name: String = #function, _ body: (Writer) -> Void)`;
  `Writer` subscripts read and write, so `c[countCog] += 1` works; unforgeable
  turn IDs; idle → accumulating → flushing; nested commits join; commits
  during a flush wait in a FIFO queue.
- Flush: the six normative steps of §3.2. Equality-gate staged writes, push
  dirty flags, settle hot roots (cold branches stay dirty), notify boundaries
  and streams (streams stub until M7), run reactions in registration order.
- Graph state: CLEAN/CHECK/DIRTY plus versions; `Equatable`, custom
  `equals:`, or assume-changed; edges reused and removed on recapture.
- Cycles: computing-mark detection; the full descriptor-and-key path in
  the diagnostic; an internal seam so tests inspect without crashing (§2.4).
- Mechanisms and reactions: the `Mechanism` protocol with a defaulted `name`
  and `operate(_:)`; the curated `MechanismController` with `run`,
  `watch(_:initial:name:)`, `task(name:)`, `whenever`, untracked `peek`, and
  the shared `CogOps` ops surface — never raw `Cogs`; bootstrap-only
  registration in array order with duplicate-name rejection; state-gated
  `whenever` scopes whose fall cancels their registrations and whose rise
  re-runs the body fresh, with terminal, idempotent scope cancellation kept
  as an internal invariant; runtime retention of each supplied mechanism value,
  with scope cancellation before value release; weak controller callbacks for
  delegate work that may outlive a scope; registration names composed under
  the mechanism name; write-back queues new FIFO turns; a debug turn-chain
  guard (about 64 turns) prints the causes through an internal diagnostic seam
  (§6.2–§6.4).
- Lifetime: `.app`; `.whileObserved(grace:)` with the `resetToInitial`
  manual opt-in; per-kind defaults from §5.3. A
  declaration without an explicit grace uses its context default: 30 seconds
  in production and an explicit testing override when elapsed time is under
  test. Internal graph edges never count as lifetime leases.
- Bootstrap: guard production installation so a second install fails fast.
  `M1-34a` settled the helper spellings on 2026-08-11, amended on 2026-08-14
  by the mechanism redesign: `Cogs.bootstrapApp(mechanisms:)` from `Cog` and
  `Cogs.forTesting(seeding:mechanisms:)` from `CogTesting` — the seeding
  closure runs before any `operate` — with a `package`
  initializer so neither can be bypassed. Add the `CogTesting` isolated-context factory for tests and
  previews. Introduce its injected clock and cleanup-acknowledgement seams
  independently near the start of M1; `whileObserved` grace timing runs on the
  context's clock, so lifetime tests never wait wall-clock time. Verify that
  separate preview runtimes neither share values nor touch the production
  install guard.
- Seeding: debug-only `CogTesting.seed` stages a value and pushes dirty flags,
  with no turn, notice, or reaction (§6.6).
- Debug history: a bounded log of ops, writes, recomputations, and
  notices, exposed as structured snapshots without a logging convenience;
  zero release-build cost.
- Test seams and traps: the cycle diagnostic, turn-chain warning,
  no-consumer warning, and cross-executor cleanup acknowledgements are named
  diagnostic seams exposed through `CogTesting` — narrow behavior contracts,
  never peeks at state storage or graph representation. Trap guarantees (a
  second production context, an escaped writer, a commit during derived
  computation) are proven with Swift Testing exit tests in the debug and
  release legs, so no trap check crashes the suite process and no guard needs
  a test-only failure hook in the library.

Tests use Swift Testing on the host in all four legs, under the scenarios.md
testing constraints. Cover the union of §11.1
and perf §9.1: diamonds; deep and broad graphs; changing and conditional
dependencies; self and multi-state cycles; escaped writers; reaction write-back
ordering; the finite turn-chain diagnostic; correct untracked reads;
MainActor execution and non-`Sendable` values; second-production-context
rejection; scene recreation without manual-state loss; equality-gated
notifications; manual lifetime; `whileObserved` release and recreate without
graph edges acting as leases; seed-then-turn settling (the §6.6 alert test
verbatim); sibling commits as separate turns; off-MainActor context deinit
tearing down mechanism scopes with deterministic MainActor cleanup
acknowledgements; preview isolation; bootstrap ordering, duplicate-name
rejection, `whenever` gating, retained mechanism-resource lifetime, and
weak external callbacks that become inert at teardown; and named,
mechanism-attributed runs in history.

<a id="plan-m2"></a>

### M2: SwiftUI boundary and weather example (spike §11.2)

- Registrar-backed boundary objects, created lazily on the first UI read: one
  phantom key path, `withMutation` only when the value changes. UI-read states
  stay pinned to the app context (§5.3, perf §6).
- The `\.cogs` environment key; every consuming view resolves it directly, and
  no view accepts or forwards `Cogs`; tracked `cogs[valueReference]` in `body`;
  application-owned SwiftUI bindings pair that tracked read with an existing
  domain operation; non-tracking one-shot `cogs.peek(valueReference)`.
- Escaping closures use one-shot `cogs.peek`. `M2-07` confirmed that public
  Observation exposes no current-consumer query, so the direct subscript
  API cannot diagnose a missing UI consumer without false positives. Ship no
  warning or private-SPI heuristic; §7 and §10 record the deferred diagnostic.
- Implement the §3 feature in `swift/Examples/Weather`: per-ZIP keyed updates,
  `fileprivate` sources plus ops, a bootstrap-registered weather mechanism,
  and bindings.
  Verify per-ZIP invalidation, equality-gated derived notices, and a view that
  reads two values changed in one commit without ever rendering a torn pair.
  Verify that boundary notices and their history entries precede reaction
  runs. Test UIKit automatic tracking on an iOS 26 simulator (files behind
  `#if canImport(UIKit)` in `CogBoundaryTests`) and AppKit automatic tracking
  on the macOS 26 host (files behind `#if canImport(AppKit)`).
- Weather proceeds in two branches. `M2-14a` creates the app and state layer,
  allowing `M2-15` UI work to proceed independently. `M2-14b` joins that app
  to the complete `Mechanism` contract after M1's bootstrap-registration,
  gated-scope, task-ownership, hourly-clock, and deinit-cleanup leaves are
  green. `M2-16` joins both branches; the example never carries a local
  lifecycle substitute or a partially implemented mechanism surface.
- Read spelling: `M2-17a` originally compared an explicit method, a subscript,
  and callable value references in a small tracked-view prototype. The settled
  spelling is now `c[valueReference]` for tracked selector and reaction reads,
  `cogs[valueReference]` for tracked UI reads, and `peek(...)` for
  non-tracking reads. Selector, reaction, and writer capabilities are all named
  `c` at their call sites.
- CI: add `test-simulator`
  (`xcodebuild test -scheme cog-Package -destination
'platform=iOS Simulator,…' -only-testing:CogBoundaryTests`), plus a
  Weather build so the example cannot rot.
- Optional nightly job if a reliable floor runtime becomes available: install
  an iOS 17.5 (build 21F79) simulator and run the core tracked-read,
  unrelated-write, equality-gated notice, and immediate-binding boundary
  scenarios. M7 extends this job with the pre-iOS-26 `c.track` re-arm
  scenarios. Too slow for per-PR. `M2-18a` identified the intended component
  and Apple-documented download/import mechanism, but the real runner's pinned
  Xcode 26.6 rejected exact-build downloads with both `arm64` and `universal`
  variants on August 12, 2026. The catalog's raw artifact requires
  authentication, so there is no verified provisioning or recovery path. The
  project owner retired this requirement on August 12, 2026 and accepted the
  current simulator lane as the compatibility gate for now. Reintroducing a
  floor nightly requires a new task after a runtime can pass import, boot,
  reboot, and a focused boundary run on `homemac`.

<a id="plan-m3"></a>

### M3: First async slice (moved up from spike §11.6)

Limit this milestone to the async pieces needed for 0.1.0:

- `CogStatus<Value>` with a three-valued `kind`, total `value`, `hasSucceeded`,
  and loading/error accessors, plus the value projection so async and manual
  values read alike. SwiftUI observes each field independently. There is no
  observable `initial` kind: first read starts work, publishes
  `kind == .pending`, `value == default`, and `hasSucceeded == false` as a turn,
  and returns that status.
- `AsyncCog` and `AsyncCogBox`: synchronous tracked selectors returning
  `Work.run`; the `.latest` policy with generation numbers (the MainActor
  commits a result only if its generation is still current); each visible
  status change is its own turn; replaced-cancelled work publishes no failure.
- Safe release: cancel and advance the generation on `.whileObserved` expiry
  (§5.3).
- A `cogs.refresh(valueReference)` op returning an exact-generation
  `CogRefresh` outcome; task names from descriptor labels for Instruments.
- A one-shot peek or refresh of a never-read async value reference creates its
  state and starts exactly one initial run with `kind == .pending`,
  `value == default`, and `hasSucceeded == false`. It
  installs no durable consumer: the call renews ordinary `whileObserved`
  grace, after which release cancels the work and rejects late results if no
  consumer arrived. Refresh does not initialize and then replace the first
  run.
- A one-shot peek of synchronous derived state is the same kind of transient
  demand: it installs no durable consumer, renews ordinary `whileObserved`
  grace, and releases and recreates from current dependencies after expiry.
- Tests: cancellation, stale-generation rejection, status-per-turn sequencing,
  dependency changes mid-flight, omitted-policy `.latest` behavior, release
  while pending, initial pending-to-failure turns, reload pending-to-failure
  turns with the last successful value, MainActor-by-default and `@concurrent`
  work isolation, task naming, invalidation during unobserved grace, one-grace
  release through `.latest`, keyed `.latest` spelling, refresh rejection
  during selector computation, non-reentrant UI reads through async-derived
  values, bounded grace scheduling under repeated one-shot demand, and release
  of one-shot synchronous derived demand. Use injected clocks and
  continuations; do not sleep.
- Revise `swift/Examples/Weather` around the completed slice: one keyed
  `AsyncCogBox` owns forecast request status and tasks; cards retain the last
  successful reading through reload and failure; initial loads, retries, and
  hourly updates use `refresh`; deterministic example tests prove per-ZIP
  invalidation, untorn atomic readings, failure retention, replacement, and
  reaction ordering without wall-clock waits or polling.

Deferred to M7: `.queue`, `.exhaustLatest`, `.merged`, `.stream`, exports,
query caching.

<a id="plan-m4"></a>

### M4: API review, docs, and 0.1.0 (spike §11.4)

- Read swift-state-graph source before freezing public names; credit prior
  art; compare tracked reads with capture lists. Adjust names if warranted;
  update §10.
- Complete and simplify the `CogStatus` surface — a three-valued `kind`, total
  `value`, `hasSucceeded`, `error`, and `isLoading`, independently observed at
  the SwiftUI boundary (§5.1) — so
  the public-name review and 0.1.0 freeze cover the whole status surface
  without `Previous` or weaker optional accessors (ASYNC-30).
- Adopt value-first async reads before the freeze: total `c[...]` value reads
  resting on an explicit declaration `default:`, the `status` lens on every read
  capability, and no separate `.latest` projection (§5.1; ASYNC-31 through
  ASYNC-34, with the existing async suite respelled).
- Return exact-generation `CogRefresh` handles; make `Cogs` the sole public
  runtime, with every side effect a bootstrap-registered mechanism; delegate
  bindings to domain operations; and
  ship `CogTesting.TestClock` for deterministic application schedules.
- `Cog.docc`: landing page, Getting Started, and an article on the
  one-context rule and testing with `CogTesting`. Start `CHANGELOG.md`.
- Close the behavior-coverage corners the scenario audit surfaced before the
  freeze: commit-boundary settlement and the shortcut diamond (TURN-15,
  GRAPH-13), the keyed cycle release trap and the debug seed-misuse guard
  (CYCLE-07, SEED-08), mid-flush gated-scope teardown, per-key
  lifetime, queued-turn history, and per-render Observation retracking
  (MECH-11, LIFE-11, HIST-07, UI-16), and the async refresh-supersession,
  concurrent-cancellation, keyed-release, and failure-honesty corners
  (ASYNC-35 through ASYNC-39).
- Verify the four-leg matrix in CI; smoke-test a scratch iOS 17 app that
  consumes the repo URL.
- Tag `0.1.0` after M1, M2, and M3 are green and LICENSE, README pin
  instructions, and DocC are in place. Benchmark numbers are not required.
  The value-reference layout may change in 0.2 because 0.x minors may break.
- Once the immutable `0.1.0` tag exists, M5 scenario scaffolding may start
  while Pages and GitHub Release verification finish; the M5 gate still waits
  for the published 0.1.0 GitHub Release. Later commits cannot change the tag,
  so this overlap shortens the critical path without weakening either release.

<a id="plan-m5"></a>

### M5: Benchmark port (spike §11.3, perf §9.2)

- `CogScenarios`: each js-reactivity-benchmark case (Kairo diamond, deep,
  broad, unstable; dynamicBench sweeps; the Cellx lattice; keyed diamonds;
  key churn) is a struct that builds the graph, runs N turns, and records
  actual versus expected recomputation counts, parameterized over the value reference
  layout under test.
- `CogScenarioTests` asserts `actual == expected` as ordinary tests, so
  duplicate work fails CI regardless of timing noise.
- Scaffold `swift/Benchmarks` first as an empty, separate SwiftPM package and
  prove its dependencies cannot enter the shipped root package. Before adding
  a benchmark dependency or allocator backend, probe and record its canonical
  repository, minimum compatible version, exact ARC metric names, baseline
  CLI, Swift 6.2/6.3 allocator behavior, and MainActor compatibility. Then pin
  only the verified dependency/backend and add an isolation shim only if the
  probe proves one necessary. The package wraps the same scenarios in
  `Benchmark {}` closures. Metrics per perf §9.4: `.wallClock`;
  `.mallocCountTotal` with a
  **threshold of zero** for steady turns and for `box[key]` value-reference creation;
  `.peakMemoryResident` at 1,000 states; notice counts for pinned keyed
  states; and verified ARC retain and release counters. Baselines use the CLI
  spelling proven by the compatibility probe. Every baseline pins its
  environment: exact Xcode and Swift version, benchmark dependency version,
  architecture, allocator backend, and the runner environment — the pinned
  VM image, or the bare mini host if the `M5-05bb` probe shows VM noise
  breaks the thresholds. Redo malloc baselines whenever the
  supported allocator path changes, including any Swift 6.2/6.3 boundary the
  probe confirms. Per-callsite ARC attribution stays a manual `xcrun xctrace`
  workflow documented in `swift/Benchmarks/README.md`.
- Each benchmark-gated task ends by recording the measurement or provisional
  threshold needed to turn its scenario green. Baseline automation follows
  those first results; no task closes while its assigned benchmark is red.
- Add `mise run bench` and the `bench-build` CI job (release build, no
  gating yet).
- Compare the three value-reference layouts (inline `AnyHashable`, interned tokens,
  generic keyed value references) on keyed diamonds and key churn. Record results in
  [perf.md](../design/perf.md); layouts stay open until the numbers exist. Edge
  layouts cannot be compared yet: the perf §3.3 candidates presume the arena
  core, so benchmark them at the start of M6. Every behavior scenario
  implemented through M5 must pass under each value-reference layout selected by
  `COG_TEST_VALUE_REFERENCE_LAYOUT`; `mise run test:value-references` loops the complete set.

<a id="plan-m6"></a>

### M6: Data-oriented core (spike §11.5, perf §3–§8)

- M6a, runnable edge-layout gate: build arena allocation, typed value columns,
  and explicit-stack propagation over one baseline edge implementation first.
  Put both representations behind the internal test-only `COG_TEST_CORE` and
  `COG_TEST_EDGE` selectors. Only after that vertical slice runs the M5
  scenarios, implement the remaining perf §3.3 candidates (Reactively-style
  per-state prefix arrays and inline-plus-overflow), run the same correctness
  set over all three, and close the runnable edge gate at `M6-05a`. Measure
  mostly-static and high-churn dependencies next. Record the numbers in
  perf.md; only then settle the layout.
- Behind the same tests and public API: SoA columns (`flags`, `changedAt`,
  `checkedAt`, `deps`, `subs`, `boundary`, `generation`); typed
  per-descriptor value columns with pending and current values; the
  edge layout selected in M6a; explicit-stack propagation with cycle marks;
  lazy boundary creation; slot generations for safe reuse; a debug ring
  buffer with zero release cost.
- Every behavior scenario implemented through M6 passes unchanged on the
  replacement core.
- Integrate that suite by behavior group throughout M6 — manual values and
  turns, graph and cycles, reactions and lifetimes, then UI and async — using
  the internal simple/arena selector. Integration and measurement stay
  outcome-neutral: every check through `M6-12a` runs through the selector,
  and switching the default core is a publication-grade step (`M6-13`) that
  runs only after `M6-12a` records the decision. If the simple core stays,
  `M6-13` keeps the simple default and records the arena's selector-only
  disposition, so no completed work needs reverting. `mise run test:cores`
  loops the complete suite over both implementations.
- Follow the perf §5 rules (no ARC, locks, or existentials in graph walks)
  until a benchmark disproves one.
- Measure against the simple build, swift-state-graph, and raw `@Observable`
  (perf §9.3–§9.5). Enable `baseline check` gating in CI: the noise-free
  `mallocCountTotal == 0` threshold plus generous absolute time thresholds.
  Update perf.md and §10 with what the data settled.
- Tag `0.2.0` when the data-oriented core replaces the simple one (`M6-13`
  executes whichever outcome `M6-12a` records). If it does not, record why
  the simple core stays. After `M6-12b` approves that release candidate (or
  closes the no-release branch), M7's independent design and behavior tracks
  may start while any conditional tag and verification tasks finish against
  the already approved commit; the 0.3.0 tag itself still waits for the
  0.2.0 chain to resolve, per the serialized release chain.

<a id="plan-m7"></a>

### M7: Async completion and exports (rest of spike §11.6)

The milestone has four dependency tracks. The `.queue` failure decision gates
only ordered-policy work; stream termination, failure, and equality settle as
three independent stream decisions; exports and external Observation tracking
proceed independently. The tracks converge only for the complete-suite and
release gates.

- `OrderedPolicy`: `.queue`; `.exhaustLatest` (finish, coalesce, catch up
  once); `.merged`. The `LatestPolicy`/`OrderedPolicy` type split keeps
  `.stream` `.latest`-only by construction (§5.2).
- `Work.stream`: each element is its own turn; a dependency change cancels
  and restarts the sequence; release of a live stream cancels it, and late
  elements commit nothing. Settle the open §10 questions on stream
  termination and failure before implementing.
- `cogs.values(of:buffering:)`: a current-value-first multicast
  `AsyncSequence`; `.newest(1)` default, plus `.oldest(n)` and `.unbounded`;
  independent per-subscriber buffers and graph leases (§8). Test exact
  overflow sequences for all three policies, subscriber independence, and
  buffer offers before reactions. Validate the §6.5 view-scoped `.task`
  pattern in the example app.
- The `c.track` shim for external `@Observable` objects, in both its
  key-path and closure forms: re-armed `withObservationTracking` before
  iOS 26, `Observations` on 26 and later (§8). Test the newest post-mutation
  value after each propagation boundary, allowed coalescing, property
  granularity, deterministic re-arm acknowledgement, and the documented
  pre-iOS-26 disarmed race. Never assert only that recomputation occurred.
- Run the complete behavior suite on the selected value-reference layout and
  data-oriented core after the M7 features land.
- Tag `0.3.0`. Query caching (`.cache`), persistence helpers, and the
  debug-history UI stay deferred backlog (§5.3, §10 items 5 and 7).

## Release process

- Tags: use bare, annotated semver git tags (`0.1.0`) permanently. Bare tags
  belong to the Swift package. Kotlin releases through Maven coordinates
  and, if it ever wants tags, uses namespaced ones (`kotlin/1.2.3`), which
  SwiftPM ignores. The repo is jj-colocated and jj does not author annotated
  tags, so a tag task runs `git tag -a` in the colocated repo and pushes the
  tag with `git push origin <tag>`; all other pushes go through
  `jj git push`.
- 0.x policy: minor may break; patch is additive or a fix. The README
  tells consumers to pin
  `.package(url: "https://github.com/skeswa/cog.git", .upToNextMinor(from: "0.1.0"))`.
  `CHANGELOG.md` calls out breaking changes per minor. No `@frozen`, no
  stability promises before 1.0.
- Docs: publish DocC to GitHub Pages through the env-gated swift-docc-plugin in
  `swift-docs.yml` on tag push (`upload-pages-artifact` plus
  `deploy-pages`); URL `https://skeswa.github.io/cog/documentation/cog/`.
  Fallback: `xcodebuild docbuild` plus `docc process-archive`, which needs
  no package dependency.
- Checklist: before tagging, run `fmt:check` and `test:matrix` locally, then
  confirm CI, simulator tests, and the Weather build are green. From M5 on,
  record `mise run bench` with its pinned environment and run `baseline check`
  once baselines exist. Version 0.1.0 predates the benchmark package and skips
  those steps. Update the CHANGELOG, tag, and push. Then verify the Pages
  deploy, create a GitHub Release with the changelog excerpt, and smoke-test
  `exact:` consumption from a scratch iOS 17 app.
- Task boundaries: build and exercise release automation first; close a
  non-mutating release-candidate gate with immutable CI links second; create
  and push the annotated tag third; then verify Pages and exact consumption
  before creating the GitHub Release. The tag task never also owns workflow
  creation, deployment troubleshooting, or post-release smoke testing.
- Serialization: releases form one dependency-ordered chain. A tag task
  depends on the previous release's terminal task — including a conditional
  release's recorded not-applicable closure — so publications never
  interleave, and the ledger checker enforces the chain. A patch release
  (for example `0.1.1`) inserts a new candidate → tag → verification →
  GitHub Release link into the chain, reusing the M4 task template.

## Kotlin headroom

- Only `Package.swift`, `.swift-format`, and `LICENSE` are Swift-flavored root
  files. The root `tools/` directory holds platform-neutral repository
  validation. Everything else Swift lives under `swift/`, leaving `kotlin/`
  as a sibling Gradle project.
- Bare semver tags are reserved for Swift; Kotlin versioning is Maven-based.
- CI is path-filtered per platform (`swift/**` now, `kotlin/**` later); mise
  tasks are namespaced (`fmt:swift` now, `fmt:kotlin` later) under repo-wide
  umbrellas.
- Record Swift spike results that may inform Kotlin as notes in the Kotlin
  ledger ([../../kotlin/exploration.md](../../kotlin/exploration.md) §10). Do
  not
  apply Swift decisions to Kotlin automatically.

## Documentation obligations (every milestone)

- Settled decisions → exploration §10 and the [README.md](../README.md)
  "Where things stand" snapshot.
- Benchmark results → perf.md; representation choices stay open until
  measured.
- Build, test, and bench commands → `CLAUDE.md` and `AGENTS.md`, in sync.
- New documents → mapped in `docs/swift/README.md` or the root `README.md`.
- New or retired scenarios → [tasks.md](./tasks.md), in the same change:
  every scenario ID stays covered by exactly one task's _Greens:_ line.
- New, split, or reordered tasks → update `_Depends:` and `_Verify:` in the
  same change and keep `mise run tasks:check` green.
- Task changes → the GitHub issue mirror (new, re-linked, or closed issues
  per the "Task bookkeeping" section), in the same change.
- Milestone scope, order, exit, public-command, gate, release-boundary, or
  non-blocking-policy changes → update both this plan and the affected task
  section, including the plan-to-task table, in the same change.

## Verification

- M0 (`M0-10`): `mise run fmt:check`, `mise run tasks:check`,
  `mise run test:matrix`, `mise run test:release`, and
  `mise run test:compilefail` pass on the stub; CI is green end to end; a
  leg-assertion test confirms the env legs really change test-target flags;
  the test wrapper's sentinel filter succeeds and an unmatched filter fails.
- M1 (`M1-33c` → `M1-32`): the full test matrix above is green in all four
  legs and in the `test-release` leg; escaped-writer, second-context, and cycle
  tests assert failure in debug and release alike.
- M2 (`M2-16` → `M2-20`): run Weather in a simulator; confirm one ZIP's write
  re-renders only that ZIP's card (`Self._printChanges` or re-render counters),
  a two-value view never renders a torn pair, and UI notices precede reactions;
  UIKit check on an iOS 26 simulator. Run the pinned iOS 17 boundary subset
  when that nightly job is available.
- M3 (`M3-11`): async tests deterministic and green; a pending fetch cancelled
  by release commits nothing; initial and reload failures each produce the
  specified pending and failure turns.
- M4 (`M4-05b` → `M4-05e`): approve a non-mutating candidate, push the tag,
  then prove a scratch iOS 17 app consumes exact 0.1.0 and the DocC site
  deploys before publishing the GitHub Release.
- M5 (`M5-10`): run-count tests are green under every value-reference candidate selected
  by `COG_TEST_VALUE_REFERENCE_LAYOUT`; the `mallocCountTotal == 0` steady-turn threshold
  holds; value-reference layout numbers are recorded in perf.md before the choice settles.
- M6 (`M6-05a`, then `M6-13` → `M6-12b`): the M5 set is green under every
  arena edge candidate; `mise run test:cores` is green; edge-layout and
  runtime-comparison numbers are recorded before choices settle; the default
  core matches the decision `M6-12a` recorded. Continue through `M6-12c`–
  `M6-12e` only if `M6-12a` approves 0.2.0.
- M7 (`M7-16a` → `M7-16e`): exact export buffers, subscriber independence,
  stream-before-reaction order, and external post-mutation value tests are
  green; the complete behavior suite passes on the selected core before the
  release sequence starts.
- Always: formatting and task-ledger checks clean; path-filtered CI green.

## Flagged uncertainties (verify at implementation time)

- Mac mini runner topology: resolved by `M0-05a` on 2026-08-10 in favour of
  persistent bare metal, which moots the VM-only questions (orchestrator
  maturity, the Virtualization.framework two-VM limit, simulator
  performance inside a VM) unless the deferred Tart upgrade is ever taken.
  `M2-18a` selected iOS 17.5 build 21F79 as the intended floor. The runner had
  83 GiB free but no iOS 17 runtime on August 12, 2026, and Xcode 26.6 then
  rejected that exact build as unavailable with both CLI architecture
  selections. Because no reproducible authenticated acquisition path was
  established, the project owner retired the requirement on August 12, 2026.
  Import, boot, post-reboot availability, and focused boundary behavior remain
  prerequisites for any future task that restores floor coverage.
- VM-versus-bare-metal benchmark noise on the mini (probed at `M5-05bb`
  before baselines are recorded).
- Benchmark package canonical repository, ARC metric names, minimum version,
  baseline CLI, allocator backend across Swift 6.2/6.3, and MainActor
  compatibility.
- SwiftPM env-var manifest re-evaluation (expected fine; fallback
  `--manifest-cache none`).
- Whether the per-PR simulator job is fast enough, or should move to
  merge-queue or nightly.
- A missing-consumer warning for tracked UI reads is unavailable with public
  Observation today. `M2-07` defers it until the framework exposes an exact
  current-tracking query; the direct subscript spelling and automatic framework
  tracking remain unchanged.
