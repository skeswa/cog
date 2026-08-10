# Cog for Swift: implementation plan

_August 8, 2026_

This document turns the spike plan in [exploration.md](./exploration.md) §11,
as amended by [perf.md](./perf.md) §9, into concrete milestones, and adds the
packaging, lint, test, CI, and release infrastructure the design documents do
not cover. The goal is a library consumable in real iOS projects soon, in a
repository that leaves room for the future Kotlin library.

The design itself is settled in the other documents; this plan does not
re-litigate it. The decision ledger stays in exploration §10.

## Plan decisions

Three choices shape this plan beyond the design documents:

- **Repo layout:** `Package.swift` lives at the repository root, because
  SwiftPM requires the manifest at the git root for URL-based consumption;
  there is no subdirectory option for remote dependencies. All Swift sources
  live under `swift/` via custom target `path:` values (the firebase-ios-sdk
  monorepo pattern). A future `kotlin/` directory joins as a sibling that
  SwiftPM never sees.
- **Lint and format:** the toolchain's `swift format` only, both formatting
  and `lint --strict`. No SwiftLint.
- **Release order:** async `.run` and `.latest` move ahead of the
  data-oriented core so 0.1.0 is usable in a real app. The rest of §11's
  order is preserved: benchmarks before the data-oriented core, and the
  public-name freeze only after the swift-state-graph review.

Constraints carried from the design documents, restated for execution:

- One app-wide `Cogtext`; guarded production construction; tests and previews
  get isolated contexts through the testing product.
- `commit(_:_:)` is the only write primitive; writer turn IDs; three context
  phases; the six-step normative flush order (exploration §3.2).
- Lazy pull plus pushed dirty flags; CLEAN, CHECK, and DIRTY states with
  versions; equality gates; dynamic dependencies recaptured every run.
- `CogPhase` with an explicit `Previous`; async selectors are synchronous and
  return `Work`; `.latest` is the default; streams are `.latest`-only.
- Public refs stay resilient (no `@frozen` in source) and never expose arena
  slots; ref, edge, and hash layouts stay open until benchmarks decide
  (perf §4, §9).
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
│   │   └── CogScenarios/             # benchmark graph scenarios + expected run
│   │                                 #   counts, shared by tests and benchmarks;
│   │                                 #   exported as non-API product _CogScenarios
│   ├── Tests/
│   │   ├── CogTests/                 # correctness suite (host-runnable)
│   │   ├── CogScenarioTests/         # run-count assertions over CogScenarios
│   │   └── CogBoundaryTests/         # Observation/SwiftUI boundary; UIKit files
│   │                                 #   behind #if canImport(UIKit)
│   ├── Benchmarks/                   # SEPARATE SwiftPM package so benchmark
│   │   └── Package.swift             #   deps never touch the shipped library
│   └── Examples/
│       └── Weather/                  # Xcode app project; local-path dep on root
└── kotlin/                           # future — never referenced by Package.swift
```

Products: `Cog`, `CogTesting` (depends on Cog), and `_CogScenarios` (for the
benchmark package only). `seed` lives in Cog behind `#if DEBUG` per §6.6.

Key manifest choices:

- `platforms: [.iOS(.v17), .macOS(.v14)]` — macOS 14 is the Observation floor
  and lets nearly all tests run host-side through `swift test`, no simulator.
- Library `swiftSettings`: Swift 6 language mode,
  `.defaultIsolation(MainActor.self)` (the SE-0466 manifest API is why the
  tools version is 6.2), `NonisolatedNonsendingByDefault`, plus
  `ExistentialAny`, `MemberImportVisibility`, and `InternalImportsByDefault`.
  Public declarations still state isolation explicitly (exploration §7).
- **Isolation test matrix:** the library's flags are fixed; only test targets
  vary, driven by environment variables read in the manifest
  (`COG_TEST_ISOLATION=nonisolated`, `COG_TEST_NNBD=1`). Four legs =
  {MainActor-default, nonisolated} × {NNBD on, off}, all running the same
  test targets. Sanity-check during M0 that environment changes bust the
  manifest cache (fallback: `--manifest-cache none`), and mirror each leg
  into a `.define()` so tests can assert which leg they run in.
- swift-docc-plugin is an environment-gated dependency (`COG_DOCC=1`, set
  only by the docs workflow), so consumers resolve a zero-dependency package.

## Milestones

### M0 — Scaffolding (the repo becomes a package)

- Root `Package.swift` as above, with a stub `Cog` target so CI runs end to
  end. Add `LICENSE`.
- `.swift-format` config: start from `swift format dump-configuration`, trim,
  two-space indent.
- `mise.toml`: restructure `fmt` into `fmt:md` and `fmt:swift` subtasks under
  umbrella `fmt` and `fmt:check` tasks
  (`swift format --in-place --parallel --recursive swift Package.swift`);
  add `test` and `test:matrix` (loops the four environment legs). The `bench`
  task arrives with the benchmark package in M5. mise cannot pin Xcode —
  document the required Xcode in the README; CI pins through `xcode-select`.
- CI: `swift-ci.yml` with concurrency-cancel and path filters
  (`Package.swift`, `swift/**`, `.swift-format`, the workflow itself). M0
  ships only the jobs its stub target can satisfy: `format` (swift format
  lint) and `test-host` (four-leg matrix of `swift test --parallel`, `.build`
  cached per leg). The `test-simulator` job is added in M2 with
  `CogBoundaryTests`, and the `bench-build` job in M5 with the benchmarks
  package. Runner: the `macos-26` image with an explicitly pinned Xcode
  26.x — verify exact image contents against `actions/runner-images` when
  writing the workflow. `markdown.yml` runs oxfmt on ubuntu.
- Update the root `README.md` status, `docs/swift/README.md`, and `CLAUDE.md`
  plus `AGENTS.md` (build and test commands now exist; keep the two in sync).

### M1 — Simple correctness core (spike §11.1)

The class-node build, prioritizing provable correctness; no perf tricks.

- **Naming:** internal final-class descriptors (`ObjectIdentifier` identity,
  `name:` or `fileID:line` labels); public ref values `Cog<T>`,
  `ManualCog<T>`, and the `CogBox`/`ManualCogBox` boxes; inline
  `AnyHashable?` keys; allocation-free `box[key]` ref creation; the
  `.readOnly` projection.
- **Cogtext:** node storage keyed by descriptor plus key; lazy node creation;
  `get`, `read`, and `curr` on the tracking controller; a MainActor-confined
  tracking slot.
- **Turns:** `commit(_ name: String = #function, _ body: (Writer) -> Void)`;
  `Writer` subscripts that read and write, so `w[count] += 1` works;
  unforgeable turn IDs; idle → accumulating → flushing; nested commits join;
  a FIFO queue for commits that arrive during a flush.
- **Flush:** the six normative steps of exploration §3.2 — equality-gate
  staged writes, push dirty flags, settle hot roots while cold branches stay
  dirty, notify boundaries and streams (the stream part stubs until M7), and
  run reactions in registration order.
- **Graph state:** CLEAN, CHECK, and DIRTY plus version numbers;
  `Equatable`, custom `equals:`, or assume-changed equality; edge reuse and
  removal on recapture.
- **Cycles:** computing-mark detection, the full descriptor-and-key path in
  the diagnostic, and an internal seam so tests inspect without crashing
  (§2.4).
- **Reactions and effects:** `cogs.run`, `cogs.watch(_:initial:name:)`,
  final-class `ReactionToken`, `EffectGroup` with `add` and `task(name:)`,
  idempotent cancel plus deinit cancel; write-back queued as new FIFO turns;
  the debug quiescence guard (about 64 turns) printing the causal chain
  (§6.4).
- **Lifetime:** `.app`, `.whileObserved(grace:)` with the `resetToInitial`
  manual opt-in, and `keepAlive` sugar; per-kind defaults from §5.3.
- **Bootstrap:** guarded production install (a second install fails fast);
  the `CogTesting` isolated-context factory. The helper spellings
  (`installApp()` and `testing()` are placeholders) get settled here — record
  the choice in §10 and the README snapshot.
- **Seeding:** debug-only `seed` that stages a value and pushes dirty flags
  with no turn, notice, or reaction (§6.6 footnote semantics).
- **Debug history:** a bounded log of ops, writes, recomputations, and
  notices; `os_log` display for now; zero release-build cost.

Tests (Swift Testing, host-side, all four matrix legs): the union of §11.1
and perf §9.1 — diamonds, deep and broad graphs, changing and conditional
dependencies, self and multi-node cycles, escaped writers, reaction
write-back ordering, the quiescence guard, second-production-context
rejection, scene recreation without manual-state loss, equality-gated
notifications, manual lifetime, `whileObserved` release and recreate, and
seed-then-turn settling (the §6.6 alert test verbatim).

### M2 — SwiftUI boundary and the weather example (spike §11.2)

- Registrar-backed boundary objects created lazily on the first UI read (one
  phantom key path; `withMutation` only on real change); UI-read nodes pinned
  to the app context (§5.3, perf §6).
- The `\.cogs` environment key; tracked `cogs.get` reads in `body`;
  `binding(for:)` pairing a tracked read with a named commit; untracked
  one-shot `cogs.read`.
- A debug warning when a tracked `get` runs with no consumer
  (escaping-closure misuse, §7).
- `swift/Examples/Weather`: the §3 weather feature built for real — per-ZIP
  keyed updates, `fileprivate` sources plus ops, an effects group, and
  bindings. Verify per-ZIP invalidation and equality-gated derived notices;
  test UIKit automatic tracking on an iOS 26 simulator (files behind
  `#if canImport(UIKit)` in `CogBoundaryTests`).
- **Resolve open question 1 (read spelling)** by trying `cogs.get(ref)`,
  `cogs[ref]`, and callable refs in the example; record the winner in §10 and
  the README snapshot.
- CI: add the `test-simulator` job to `swift-ci.yml`
  (`xcodebuild test -scheme cog-Package -destination
'platform=iOS Simulator,…' -only-testing:CogBoundaryTests`, plus building
  the Weather example so it cannot rot).
- Optional nightly CI job once the floor shims exist: install an iOS 17.x
  simulator runtime and run `CogBoundaryTests` against the real floor to
  validate the `withObservationTracking` re-arm path — too slow for per-PR.

### M3 — Async cogs, first slice (reordered from spike §11.6)

Only what a real app needs for 0.1.0:

- `CogPhase<Value>` plus `Previous<Value>`, `latestValue`, and `isLoading`;
  the `.latest` projection so async and manual values read alike.
- `AsyncCog` and `AsyncCogBox` with synchronous tracked selectors returning
  `Work.run`; the `.latest` policy with generation numbers (the MainActor
  commits a result only if its generation is current); each visible phase
  change is its own turn; replaced-cancelled work publishes no failure.
- Safe release: cancel plus generation advance on `.whileObserved` expiry
  (§5.3).
- A `cogs.refresh(ref)` forced-refresh op; task names from descriptor labels
  for Instruments.
- Tests: cancellation, stale-generation rejection, phase-per-turn
  sequencing, dependency change mid-flight, and release-while-pending — all
  deterministic (injected clocks and continuations, no sleeps).

Deferred to M7: `.queue`, `.exhaustLatest`, `.merged`, `.stream`, exports,
and query caching.

### M4 — API review, docs, and 0.1.0 (spike §11.4)

- Read swift-state-graph source before freezing public names; credit prior
  art; compare tracked reads with capture lists (§11.4). Adjust names if
  warranted; update §10.
- The DocC catalog (`Cog.docc`): a landing page, Getting Started, and an
  article on the one-context rule and testing with `CogTesting`. Start
  `CHANGELOG.md`.
- Verify the four-leg isolation matrix in CI; smoke-test consumption from a
  scratch iOS 17 app through the repo URL.
- Tag `0.1.0` (see the release process). 0.1.0 = M1 + M2 + M3 working, tests
  green, LICENSE plus README pin instructions plus DocC in place. Benchmark
  numbers need not be settled — the ref layout may change in 0.2 because 0.x
  minors may break.

### M5 — Benchmark port (spike §11.3, perf §9.2)

- The `CogScenarios` target: each js-reactivity-benchmark case (Kairo
  diamond, deep, broad, and unstable; dynamicBench sweeps; the Cellx lattice;
  plus keyed diamonds and key churn) is a struct that builds the graph, runs
  N turns, and records actual against expected recomputation counts,
  parameterized over the ref layout under test.
- `CogScenarioTests`: asserts `actual == expected` run counts as ordinary
  tests, so duplicate-work regressions fail CI as test failures, independent
  of timing noise.
- The `swift/Benchmarks` package (ordo-one/package-benchmark plus jemalloc,
  confined to this package and CI job): wraps the same scenarios in
  `Benchmark {}` closures. Metrics per perf §9.4: `.wallClock`,
  `.mallocCountTotal` with a **threshold of zero** for steady turns,
  `.peakMemoryResident` at 1,000 nodes, and ARC retain and release counters
  (verify exact metric names and minimum version at wiring time; also check
  whether MainActor-confined scenario bodies need an `assumeIsolated` shim in
  the runner). Baselines through `swift package benchmark baseline
update/check`. Every recorded baseline must pin its environment: exact
  Xcode and Swift toolchain version, package-benchmark version, architecture,
  and allocator backend — package-benchmark takes malloc counts from jemalloc
  through Swift 6.2 but switches to a malloc interposer from Swift 6.3
  onward, and malloc baselines must be re-established across that boundary.
  Deep per-callsite ARC attribution stays a manual `xcrun xctrace` workflow
  documented in `swift/Benchmarks/README.md`.
- Add the `mise run bench` task and the `bench-build` CI job (release-build
  the benchmarks package; no gating yet).
- Compare the three ref layouts (inline `AnyHashable`, interned tokens, and
  generic keyed refs) on keyed diamonds and key churn. **Record results in
  [perf.md](./perf.md) — layout choices stay open until these numbers
  exist.** Edge layouts are not comparable yet: the candidates in perf §3.3
  presume the arena core, so their benchmark happens at the start of M6.

### M6 — Data-oriented core (spike §11.5, perf §3–§8)

- **M6a — edge-layout comparison (gate for the rest of M6):** build the SoA
  arena core with the edge representation behind an internal seam, implement
  the three perf §3.3 candidates (shared linked edge pool, Reactively-style
  per-node prefix arrays, and inline-plus-overflow), and run the M5 scenario
  suite over all three — mostly-static graphs and high-churn dynamic
  dependencies must both be measured. Record the numbers in
  [perf.md](./perf.md) and only then settle the layout.
- Behind the same test suite and public API: the SoA columns (`flags`,
  `changedAt`, `checkedAt`, `deps`, `subs`, `boundary`, `generation`), typed
  per-descriptor value columns with pending and current values, the
  M6a-winning edge layout, explicit-stack propagation with cycle marks, lazy
  boundary creation, slot generations for safe reuse, and the debug ring
  buffer with zero release cost.
- Follow the perf §5 rules (no ARC, locks, or existentials in graph walks)
  until a benchmark disproves one.
- Measure against the simple build, swift-state-graph, and raw `@Observable`
  (perf §9.3–§9.5); enable `baseline check` gating in CI with the noise-free
  `mallocCountTotal == 0` threshold plus generous absolute time thresholds.
  Update perf.md and §10 with what the data settled.
- Tag `0.2.0` when the data-oriented core replaces the simple one — or record
  why the simple core stays.

### M7 — Async completion and exports (rest of spike §11.6)

- The `OrderedPolicy` policies: `.queue`, `.exhaustLatest` (finish, coalesce,
  catch up once), and `.merged`; the `LatestPolicy`/`OrderedPolicy` type
  split so `.stream` is `.latest`-only by construction (§5.2).
- `Work.stream`: each element is its own turn; a dependency change cancels
  and restarts the sequence.
- `cogs.values(of:buffering:)` exports — a current-value-first multicast
  `AsyncSequence`, `.newest(1)` default, `.oldest(n)` and `.unbounded`, and
  per-subscriber graph leases (§8); the view-scoped `.task` pattern from
  §6.5 validated in the example app.
- The `c.track` interop shim for external `@Observable` objects (re-armed
  `withObservationTracking` before iOS 26, `Observations` on 26 and later)
  (§8).
- Tag `0.3.0`. Query caching (`.cache`), persistence helpers, and the
  debug-history UI remain explicitly deferred backlog (§5.3, §10 open items
  5 and 7).

## Tooling summary

- **Format and lint:** the toolchain's `swift format` (`--in-place` locally,
  `lint --strict` in CI) with one root `.swift-format`; Oxfmt keeps markdown.
  Umbrella `mise run fmt` and `fmt:check` cover both.
- **Testing:** Swift Testing (`@Test`, `#expect`), zero dependencies.
  Host-side `swift test` covers the graph core, scenarios, and even the
  Observation-boundary tests, since macOS 14 has Observation and SwiftUI;
  only UIKit checks, iOS 17 floor validation, and the example app need a
  simulator. `mise run test:matrix` runs the four isolation legs locally.
- **Benchmarks:** ordo-one/package-benchmark in the isolated
  `swift/Benchmarks` package (jemalloc supplies malloc counters); run-count
  correctness lives in the main package's tests; xctrace for manual ARC deep
  dives. `mise run bench`.
- **CI:** GitHub Actions on `macos-26` with a pinned Xcode 26.x (verify image
  contents at write time); jobs for format, four-leg host tests, simulator
  boundary tests, and the bench build — each job introduced in the milestone
  that creates its target (M0, M0, M2, and M5); path-filtered so `docs/**`
  and the future `kotlin/**` never trigger Swift CI; the markdown check runs
  on cheap ubuntu.

## Release process

- **Tags:** bare semver git tags (`0.1.0`), annotated, forever. Bare semver
  tags belong to the Swift package; Kotlin later releases through Maven
  coordinates and, if it ever wants tags, uses namespaced ones
  (`kotlin/1.2.3`), which SwiftPM ignores.
- **0.x policy:** minor may break; patch is additive or a fix. The README
  instructs consumers to pin
  `.package(url: "https://github.com/skeswa/cog.git", .upToNextMinor(from: "0.1.0"))`.
  `CHANGELOG.md` calls out breaking changes per minor. No `@frozen` and no
  stability promises before 1.0.
- **Docs:** DocC published to GitHub Pages through the environment-gated
  swift-docc-plugin in `swift-docs.yml` on tag push (`upload-pages-artifact`
  plus `deploy-pages`); URL `https://skeswa.github.io/cog/documentation/cog/`.
  Fallback if the environment gate misbehaves: `xcodebuild docbuild` plus
  `docc process-archive`, which needs no package dependency.
- **Checklist per release:** local `fmt:check` and `test:matrix` green; CI
  green; simulator tests and the Weather build pass; from M5 on,
  `mise run bench` recorded with its pinned environment (and `baseline check`
  once baselines exist) — 0.1.0 ships before the benchmark package and skips
  this step; CHANGELOG updated; tag and push; verify the Pages deploy; a
  GitHub Release with the changelog excerpt; smoke-test `exact:` consumption
  from a scratch iOS 17 app.

## Kotlin headroom

- Only `Package.swift`, `.swift-format`, and `LICENSE` are Swift-flavored
  root files; everything else Swift lives under `swift/`, so `kotlin/` (a
  Gradle project) lands as a clean sibling that SwiftPM never sees.
- Bare semver git tags are reserved for the Swift package; Kotlin versioning
  is Maven-based and tag-independent.
- CI is path-filtered per platform (`swift/**` now, `kotlin/**` later); mise
  tasks are namespaced (`fmt:swift` now, `fmt:kotlin` later) under repo-wide
  umbrellas.
- No Swift decision transfers silently: spike learnings that should inform
  Kotlin get recorded as notes for the Kotlin ledger
  ([../kotlin/exploration.md](../kotlin/exploration.md) §10), not assumed.

## Documentation obligations (every milestone)

- Settled decisions → exploration §10 and the [README.md](./README.md)
  "Where things stand" snapshot.
- Benchmark results → perf.md; no representation choice is marked settled
  without measurements.
- Build, test, and bench commands → `CLAUDE.md` and `AGENTS.md`, kept in
  sync.
- New documents (a benchmark README, a contributor guide) → mapped in
  `docs/swift/README.md` or the root `README.md`.

## Verification

- **M0:** `mise run fmt:check` and `mise run test:matrix` pass locally on
  the stub; CI is green end to end; confirm the environment-variable
  manifest legs actually change test-target flags (a leg-assertion test).
- **M1:** the full §11.1/perf §9.1 correctness matrix is green in all four
  legs; escaped-writer and second-context tests assert failure in every
  build.
- **M2:** run the Weather app in a simulator; confirm one ZIP's write
  re-renders only that ZIP's card (`Self._printChanges` or re-render
  counters); UIKit tracking check on an iOS 26 simulator.
- **M3:** async tests are deterministic (no sleeps) and green; a pending
  fetch cancelled by release commits nothing.
- **M4:** consume the tagged 0.1.0 from a scratch iOS 17 app through the
  repo URL and build it; the DocC site deploys.
- **M5 and M6:** scenario run-count tests green; the `mallocCountTotal == 0`
  steady-turn threshold holds; comparative numbers recorded in perf.md.
- **Always:** format checks clean; path-filtered CI green.

## Flagged uncertainties (verify at implementation time)

- Exact `macos-26` runner image contents and preinstalled Xcode 26.x
  versions (check `actions/runner-images`).
- package-benchmark's ARC metric names, minimum version, and
  MainActor-scenario compatibility.
- SwiftPM environment-variable manifest re-evaluation (expected fine;
  fallback `--manifest-cache none`).
- Whether the per-PR simulator job is fast enough or should move to
  merge-queue or nightly.
- iOS 17 simulator runtime install mechanics for the nightly floor job.
