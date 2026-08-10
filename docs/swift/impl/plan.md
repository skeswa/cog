# Cog for Swift: implementation plan

_August 9, 2026_

This plan turns the Swift spike ([exploration.md](../design/exploration.md)
§11, amended by [perf.md](../design/perf.md) §9) into milestones. It also fills in package
layout, formatting, tests, CI, and releases. The aim is to get Cog into iOS
apps soon without making a future Kotlin package awkward. The architecture is
settled elsewhere; its decision ledger stays in exploration §10. The companion
[scenarios.md](./scenarios.md) breaks these milestones into the test scenarios
that drive red-green implementation.

## Plan decisions

- Layout: `Package.swift` is at the repo root because SwiftPM resolves remote
  packages only from a git root. There is no subdirectory option. All
  Swift sources live under `swift/` through custom target `path:` values (the
  firebase-ios-sdk pattern). A future `kotlin/` directory is a sibling that
  SwiftPM never sees.
- Lint and format: use only the toolchain's `swift format`, both formatting and
  `lint --strict`. No SwiftLint.
- Order: async `.run` and `.latest` move ahead of the data-oriented core so
  0.1.0 includes the async state an app needs. Keep the rest of §11's order:
  benchmarks precede the data-oriented core, and public names remain open
  until after the swift-state-graph review.
- Testing posture (settled 2026-08-10): every test is fully optimistic, as
  fast and cheap as possible, and as implementation agnostic as possible.
  The normative statement is the "Testing constraints" section of
  [scenarios.md](./scenarios.md). The mechanisms it requires — an injected
  clock on testing contexts that drives `whileObserved` grace timing, named
  diagnostic seams exposed through `CogTesting`, Swift Testing exit tests
  for trap guarantees, and one batched expected-failure fixture pass for
  compile-fail checks — land in M0 and M1 below.

Execution constraints from the design docs:

- One app-wide `Cogtext`; guarded production construction; tests and previews
  get isolated contexts from the testing product.
- `commit(_:_:)` is the only write primitive: writer turn IDs, three context
  phases, six-step flush order (§3.2).
- Lazy pull plus pushed dirty flags; CLEAN, CHECK, DIRTY with versions;
  equality gates; dependencies recaptured every run.
- `CogPhase` begins publicly at `pending` with explicit `Previous`; async
  selectors are synchronous and return `Work`; `.latest` is the default;
  streams are `.latest`-only.
- Public refs stay resilient (no `@frozen`) and never expose arena slots.
  Ref, edge, and hash layouts wait for benchmarks (perf §4, §9).
- iOS 17 / Swift 6.2 floor; test with default MainActor isolation on and off
  and `NonisolatedNonsendingByDefault` on and off; no required macros.

## Target layout

```text
cog/                                  (git root = SwiftPM package root)
├── Package.swift                     # root manifest, swift-tools-version 6.2
├── LICENSE                           # missing today; required before 0.1.0
├── .swift-format
├── .github/workflows/
│   ├── swift-ci.yml                  # path-filtered on Package.swift + swift/**
│   ├── swift-docs.yml                # DocC → GitHub Pages, on tag push
│   └── markdown.yml                  # oxfmt --check, ubuntu, *.md paths
├── docs/                             # living design docs (unchanged)
├── swift/
│   ├── Sources/
│   │   ├── Cog/                      # the library; Cog.docc/ catalog inside
│   │   ├── CogTesting/               # isolated-Cogtext factory for tests/previews
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
benchmark package only). Compile `seed` only behind `#if DEBUG` (§6.6).

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

## Milestones

### M0: Scaffolding

- Root `Package.swift` with a stub `Cog` target so CI runs end to end. Add
  `LICENSE`.
- `.swift-format`: start from `swift format dump-configuration`, trim,
  two-space indent.
- `mise.toml`: split `fmt` into `fmt:md` and `fmt:swift`
  (`swift format --in-place --parallel --recursive swift Package.swift`)
  under `fmt` and `fmt:check` umbrellas; add `test`, `test:matrix` (loops
  the four legs), and `test:release` (`swift test -c release` on the default
  leg, so the guardrails that promise every-build behavior really run in a
  release configuration). Add `bench` in M5. mise cannot pin Xcode. The README
  documents the required version, and CI selects it with `xcode-select`.
- `swift-ci.yml`: concurrency-cancel; path filters (`Package.swift`,
  `swift/**`, `.swift-format`, the workflow itself). M0 includes only the jobs
  the stub can satisfy: `format` (swift format lint), `test-host`
  (four-leg matrix of `swift test --parallel`, `.build` cached per leg), and
  `test-release` (`swift test -c release` on the default leg — the leg where
  every-build guardrails such as the second-context guard, escaped writers,
  cycle detection, the absence of `seed`, and free debug history are proven
  outside debug). Add `test-simulator` in M2 and `bench-build` in M5. Use the `macos-26`
  runner with a pinned Xcode 26.x. Verify image contents against
  `actions/runner-images` when writing the workflow. `markdown.yml` runs
  oxfmt on ubuntu.
- Compile-fail harness: a fixtures directory of expected-failure sources,
  compiled in one batched pass by a `test:compilefail` mise task and CI step
  that asserts each fixture fails with the expected diagnostic. The
  scenarios marked "(A compile-fail check.)" all run through this harness,
  never as per-test compiler invocations.
- Update the root `README.md`, `docs/swift/README.md`, and `CLAUDE.md` plus
  `AGENTS.md` (kept in sync) with the new commands.

### M1: Simple correctness core (spike §11.1)

The class-node build. Correctness first; no perf tricks.

- Names: internal final-class descriptors (`ObjectIdentifier` identity;
  `name:` or `fileID:line` labels). Public ref values `Cog<T>` and
  `ManualCog<T>`; boxes `CogBox` and `ManualCogBox`; inline `AnyHashable?`
  keys; allocation-free `box[key]`; the `.readOnly` projection.
- Cogtext: nodes stored by descriptor plus key, created lazily; `get`,
  `read`, and `curr` on the tracking controller; a MainActor-confined
  tracking slot. Untracked reads still settle and return the latest value.
- Turns: `commit(_ name: String = #function, _ body: (Writer) -> Void)`;
  `Writer` subscripts read and write, so `w[count] += 1` works; unforgeable
  turn IDs; idle → accumulating → flushing; nested commits join; commits
  during a flush wait in a FIFO queue.
- Flush: the six normative steps of §3.2. Equality-gate staged writes, push
  dirty flags, settle hot roots (cold branches stay dirty), notify boundaries
  and streams (streams stub until M7), run reactions in registration order.
- Graph state: CLEAN/CHECK/DIRTY plus versions; `Equatable`, custom
  `equals:`, or assume-changed; edges reused and removed on recapture.
- Cycles: computing-mark detection; the full descriptor-and-key path in
  the diagnostic; an internal seam so tests inspect without crashing (§2.4).
- Reactions and effects: `cogs.run`; `cogs.watch(_:initial:name:)`;
  final-class `ReactionToken`; `EffectGroup` with `add` and `task(name:)`;
  cancel is idempotent and runs on deinit; write-back queues new FIFO turns;
  a debug quiescence guard (about 64 turns) prints the causal chain through an
  internal diagnostic seam (§6.4).
- Lifetime: `.app`; `.whileObserved(grace:)` with the `resetToInitial`
  manual opt-in; `keepAlive` as sugar; per-kind defaults from §5.3. Internal
  graph edges never count as lifetime leases.
- Bootstrap: guard production installation so a second install fails fast.
  Add the `CogTesting` isolated-context factory for tests and previews; a
  testing context accepts an injected clock, and `whileObserved` grace timing
  runs on the context's clock, so lifetime tests never wait wall-clock time.
  Verify
  that separate preview runtimes neither share values nor touch the production
  install guard. Settle the helper spellings (`installApp()` and `testing()`
  are placeholders); record in §10 and the README snapshot.
- Seeding: debug-only `seed` stages a value and pushes dirty flags, with
  no turn, notice, or reaction (§6.6).
- Debug history: a bounded log of ops, writes, recomputations, and
  notices; `os_log` display for now; zero release-build cost.
- Test seams and traps: the cycle diagnostic, quiescence warning,
  no-consumer warning, and cross-executor cleanup acknowledgements are named
  diagnostic seams exposed through `CogTesting` — narrow behavior contracts,
  never peeks at node storage or graph representation. Trap guarantees (a
  second production context, an escaped writer) are proven with Swift
  Testing exit tests in the debug and release legs, so no trap check crashes
  the suite process and no guard needs a test-only failure hook in the
  library.

Tests use Swift Testing on the host in all four legs, under the scenarios.md
testing constraints. Cover the union of §11.1
and perf §9.1: diamonds; deep and broad graphs; changing and conditional
dependencies; self and multi-node cycles; escaped writers; reaction write-back
ordering; the finite quiescence-guard diagnostic; correct untracked reads;
MainActor execution and non-`Sendable` values; second-production-context
rejection; scene recreation without manual-state loss; equality-gated
notifications; manual lifetime; `whileObserved` release and recreate without
graph edges acting as leases; seed-then-turn settling (the §6.6 alert test
verbatim); sibling commits as separate turns; off-MainActor token and group
deinit with deterministic MainActor cleanup acknowledgements; preview
isolation; and named effect runs in history.

### M2: SwiftUI boundary and weather example (spike §11.2)

- Registrar-backed boundary objects, created lazily on the first UI read: one
  phantom key path, `withMutation` only when the value changes. UI-read nodes
  stay pinned to the app context (§5.3, perf §6).
- The `\.cogs` environment key; tracked `cogs.get` in `body`; `binding(for:)`
  pairs a tracked read with a named commit; untracked one-shot `cogs.read`.
- A debug warning when a tracked `get` runs with no consumer
  (escaping-closure misuse, §7), surfaced through the diagnostic seam so
  tests assert it without scraping logs.
- Implement the §3 feature in `swift/Examples/Weather`: per-ZIP keyed updates,
  `fileprivate` sources plus ops, an effects group, and bindings.
  Verify per-ZIP invalidation, equality-gated derived notices, and a view that
  reads two values changed in one commit without ever rendering a torn pair.
  Verify that boundary notices and their history entries precede reaction
  runs. Test UIKit automatic tracking on an iOS 26 simulator (files behind
  `#if canImport(UIKit)` in `CogBoundaryTests`) and AppKit automatic tracking
  on the macOS 26 host (files behind `#if canImport(AppKit)`).
- Read spelling: try `cogs.get(ref)`, `cogs[ref]`, and callable refs in the
  example; record the winner in §10 and the README snapshot.
- CI: add `test-simulator`
  (`xcodebuild test -scheme cog-Package -destination
'platform=iOS Simulator,…' -only-testing:CogBoundaryTests`), plus a
  Weather build so the example cannot rot.
- Optional nightly job once the floor runtime is available: install a pinned
  iOS 17.x simulator and run the core tracked-read, unrelated-write,
  equality-gated notice, and immediate-binding boundary scenarios. M7 extends
  this job with the pre-iOS-26 `c.track` re-arm scenarios. Too slow for per-PR.

### M3: First async slice (moved up from spike §11.6)

Limit this milestone to the async pieces needed for 0.1.0:

- `CogPhase<Value>` plus `Previous<Value>`, `latestValue`, `isLoading`, and
  the `.latest` projection so async and manual values read alike. There is no
  observable `initial` phase: first read starts work, publishes
  `pending(previous: .none)` as a turn, and returns that phase.
- `AsyncCog` and `AsyncCogBox`: synchronous tracked selectors returning
  `Work.run`; the `.latest` policy with generation numbers (the MainActor
  commits a result only if its generation is still current); each visible
  phase change is its own turn; replaced-cancelled work publishes no failure.
- Safe release: cancel and advance the generation on `.whileObserved` expiry
  (§5.3).
- A `cogs.refresh(ref)` op; task names from descriptor labels for
  Instruments.
- Tests: cancellation, stale-generation rejection, phase-per-turn sequencing,
  dependency changes mid-flight, omitted-policy `.latest` behavior, release
  while pending, initial pending-to-failure turns, reload pending-to-failure
  turns with the last successful value, MainActor-by-default and `@concurrent`
  work isolation, and task naming. Use injected clocks and continuations; do
  not sleep.

Deferred to M7: `.queue`, `.exhaustLatest`, `.merged`, `.stream`, exports,
query caching.

### M4: API review, docs, and 0.1.0 (spike §11.4)

- Read swift-state-graph source before freezing public names; credit prior
  art; compare tracked reads with capture lists. Adjust names if warranted;
  update §10.
- `Cog.docc`: landing page, Getting Started, and an article on the
  one-context rule and testing with `CogTesting`. Start `CHANGELOG.md`.
- Verify the four-leg matrix in CI; smoke-test a scratch iOS 17 app that
  consumes the repo URL.
- Tag `0.1.0` after M1, M2, and M3 are green and LICENSE, README pin
  instructions, and DocC are in place. Benchmark numbers are not required.
  The ref layout may change in 0.2 because 0.x minors may break.

### M5: Benchmark port (spike §11.3, perf §9.2)

- `CogScenarios`: each js-reactivity-benchmark case (Kairo diamond, deep,
  broad, unstable; dynamicBench sweeps; the Cellx lattice; keyed diamonds;
  key churn) is a struct that builds the graph, runs N turns, and records
  actual versus expected recomputation counts, parameterized over the ref
  layout under test.
- `CogScenarioTests` asserts `actual == expected` as ordinary tests, so
  duplicate work fails CI regardless of timing noise.
- The `swift/Benchmarks` package (ordo-one/package-benchmark plus jemalloc,
  confined there): wraps the same scenarios in `Benchmark {}` closures.
  Metrics per perf §9.4: `.wallClock`; `.mallocCountTotal` with a
  **threshold of zero** for steady turns and for `box[key]` ref creation;
  `.peakMemoryResident` at 1,000 nodes; notice counts for pinned keyed
  nodes; ARC retain and release counters (verify exact metric names and
  minimum version; check whether MainActor-confined bodies need an
  `assumeIsolated` shim). Baselines via
  `swift package benchmark baseline update/check`. Every baseline pins its
  environment: exact Xcode and Swift version, package-benchmark version,
  architecture, and allocator backend. Package-benchmark counts mallocs with
  jemalloc through Swift 6.2 and with a malloc interposer from Swift 6.3, so
  redo malloc baselines across that boundary. Per-callsite ARC
  attribution stays a manual `xcrun xctrace` workflow documented in
  `swift/Benchmarks/README.md`.
- Add `mise run bench` and the `bench-build` CI job (release build, no
  gating yet).
- Compare the three ref layouts (inline `AnyHashable`, interned tokens,
  generic keyed refs) on keyed diamonds and key churn. Record results in
  [perf.md](../design/perf.md); layouts stay open until the numbers exist. Edge
  layouts cannot be compared yet: the perf §3.3 candidates presume the arena
  core, so benchmark them at the start of M6. Every behavior scenario
  implemented through M5 must pass under each ref layout being measured.

### M6: Data-oriented core (spike §11.5, perf §3–§8)

- M6a, edge-layout gate: build the SoA arena core with the edge
  representation behind an internal seam. Implement the three perf §3.3
  candidates (shared linked edge pool, Reactively-style per-node prefix
  arrays, inline-plus-overflow) and run the M5 scenarios over all three.
  Measure both mostly-static graphs and high-churn dynamic dependencies.
  Record the numbers in perf.md; only then settle the layout.
- Behind the same tests and public API: SoA columns (`flags`, `changedAt`,
  `checkedAt`, `deps`, `subs`, `boundary`, `generation`); typed
  per-descriptor value columns with pending and current values; the
  edge layout selected in M6a; explicit-stack propagation with cycle marks; lazy
  boundary creation; slot generations for safe reuse; a debug ring buffer
  with zero release cost.
- Every behavior scenario implemented through M6 passes unchanged on the
  replacement core.
- Follow the perf §5 rules (no ARC, locks, or existentials in graph walks)
  until a benchmark disproves one.
- Measure against the simple build, swift-state-graph, and raw `@Observable`
  (perf §9.3–§9.5). Enable `baseline check` gating in CI: the noise-free
  `mallocCountTotal == 0` threshold plus generous absolute time thresholds.
  Update perf.md and §10 with what the data settled.
- Tag `0.2.0` when the data-oriented core replaces the simple one. If it does
  not, record why the simple core stays.

### M7: Async completion and exports (rest of spike §11.6)

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
- Run the complete behavior suite on the selected ref layout and
  data-oriented core after the M7 features land.
- Tag `0.3.0`. Query caching (`.cache`), persistence helpers, and the
  debug-history UI stay deferred backlog (§5.3, §10 items 5 and 7).

## Release process

- Tags: use bare, annotated semver git tags (`0.1.0`) permanently. Bare tags
  belong to the Swift package. Kotlin releases through Maven coordinates
  and, if it ever wants tags, uses namespaced ones (`kotlin/1.2.3`), which
  SwiftPM ignores.
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

## Kotlin headroom

- Only `Package.swift`, `.swift-format`, and `LICENSE` are Swift-flavored
  root files. Everything else Swift lives under `swift/`, leaving `kotlin/`
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

## Verification

- M0: `mise run fmt:check` and `mise run test:matrix` pass on the stub;
  CI green end to end; a leg-assertion test confirms the env legs really
  change test-target flags.
- M1: the full test matrix above is green in all four legs and in the
  `test-release` leg; escaped-writer, second-context, and cycle tests assert
  failure in debug and release alike.
- M2: run Weather in a simulator; confirm one ZIP's write re-renders only that
  ZIP's card (`Self._printChanges` or re-render counters), a two-value view
  never renders a torn pair, and UI notices precede reactions; UIKit check on
  an iOS 26 simulator. Run the pinned iOS 17 boundary subset when that nightly
  job is available.
- M3: async tests deterministic and green; a pending fetch cancelled by
  release commits nothing; initial and reload failures each produce the
  specified pending and failure turns.
- M4: a scratch iOS 17 app consumes tagged 0.1.0 by URL and builds; the
  DocC site deploys.
- M5 and M6: run-count tests green under every candidate layout; the
  `mallocCountTotal == 0` steady-turn threshold holds; ref-layout, edge-layout,
  and runtime-comparison numbers are recorded in perf.md before choices settle.
- M7: exact export buffers, subscriber independence, stream-before-reaction
  order, and external post-mutation value tests are green; the complete
  behavior suite passes on the selected core.
- Always: format checks clean; path-filtered CI green.

## Flagged uncertainties (verify at implementation time)

- Exact `macos-26` runner image contents and preinstalled Xcode 26.x
  versions (check `actions/runner-images`).
- package-benchmark ARC metric names, minimum version, and MainActor
  compatibility.
- SwiftPM env-var manifest re-evaluation (expected fine; fallback
  `--manifest-cache none`).
- Whether the per-PR simulator job is fast enough, or should move to
  merge-queue or nightly.
- iOS 17 simulator runtime install mechanics for the nightly floor job.
