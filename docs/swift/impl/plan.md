# Cog for Swift: implementation plan

_August 10, 2026_

This plan defines package layout, milestones, CI, and release boundaries. The
[core design](../design/exploration.md) owns behavior.
[scenarios.md](./scenarios.md) lists test stories. [tasks.md](./tasks.md) splits
the work into tasks of half a day or less and gives each scenario one owner.

## Plan decisions

- **Layout:** the git root is the SwiftPM root. Swift code lives under
  `swift/`. A future `kotlin/` directory is a sibling that SwiftPM cannot see.
- **Formatting:** use `swift format` for Swift. `coglint` checks Cog-specific
  usage without adding source dependencies to the root package.
- **Order:** prove behavior first, then benchmark, then change representation.
  Async `.run` and `.latest` came before the arena so the first app release
  included useful async state.
- **Tests:** use clear signals, injected time, public behavior, and host tests
  where possible. [scenarios.md](./scenarios.md#testing-constraints) is the
  full rule.
- **Tasks:** work follows the dependency graph in [tasks.md](./tasks.md). Each
  task has one purpose, direct dependencies, a closing check, and a green end.
  Gates report failures but do not absorb repair work.
- **CI:** trusted macOS work runs on the repository's Actions runner. Forks use
  approval-gated hosted runners. All actions are pinned, tokens default to read
  only, checkouts drop credentials, and jobs have timeouts. The
  [CI runbook](../../maintainers/ci.md) owns runner and security details.
- **Bookkeeping:** docs define the work. GitHub issues track live ownership,
  blockers, evidence, and closure.
- **Ledger checks:** tasks that change defaults or publish wait for their
  decision gates. Releases form one ordered chain. The checker derives scenario
  counts, filter coverage, proof modes, and arena integration coverage.

The implementation must keep these design rules:

- One app-wide `Cogs`. Tests and previews get isolated contexts.
- `turn` is the only write primitive and keeps the six-step flush order.
- Dirty flags push; reads pull; equality and versions stop unneeded work.
- Async values start at `pending` with a total default value. Selectors return
  `Work`, `.latest` is the default, and streams use `.latest` only.
- Public references stay resilient and never expose arena slots.
- The floor is iOS 17 with Swift 6.2 tools. The four isolation test legs must
  behave the same.
- Macros are optional, never required.

## Target layout

```text
cog/                            # git root and SwiftPM package root
├── Package.swift               # Cog, CogTesting, and _CogScenarios
├── version.txt                 # current Swift release version
├── .github/workflows/
│   ├── swift-ci.yml            # tests and release-candidate artifacts
│   ├── conventional-commits.yml
│   ├── release.yml             # Release Please and asset publication
│   ├── docs.yml                # DocC + VitePress → GitHub Pages
│   └── markdown.yml            # docs and repository checks
├── tools/                      # guarded test and repository checks
├── docs/                       # design, plans, results, and runbooks
├── swift/
│   ├── Sources/
│   │   ├── Cog/                # shipping library and DocC catalog
│   │   ├── CogTesting/         # isolated test and preview runtimes
│   │   └── CogScenarios/       # shared benchmark graphs
│   ├── Tests/                  # behavior, run-count, and UI-boundary tests
│   ├── CompileFail/            # expected compiler errors
│   ├── Benchmarks/             # separate benchmark package
│   ├── Lint/                   # separate CogLint development package
│   ├── Storefront/             # separate shared workload package
│   └── Examples/
│       ├── Weather/            # worked app
│       └── Storefront/         # SwiftUI macrobenchmark app
└── kotlin/                     # future sibling project
```

Root products are `Cog`, `CogTesting`, and the non-API `_CogScenarios`.
`CogTesting.seed` exists only in debug builds. The separate lint package builds
`coglint`; the sibling distribution package exposes `CogLintBinary` and both
plugins.

Manifest choices:

- `platforms: [.iOS(.v17), .macOS(.v14)]`. Most tests run on macOS. UIKit and
  example checks use a simulator.
- Library settings: Swift 6 language mode,
  `.defaultIsolation(MainActor.self)` (the SE-0466 manifest API is why the
  tools version is 6.2), `NonisolatedNonsendingByDefault`, `ExistentialAny`,
  `MemberImportVisibility`, `InternalImportsByDefault`. Public declarations
  still state isolation explicitly (§7).
- Isolation matrix: the same tests run under {MainActor, nonisolated} × {NNBD
  on, off}. Environment values select a leg, and test defines prove which leg
  ran. `--manifest-cache none` is the stale-cache fallback.
- swift-docc-plugin is env-gated (`COG_DOCC=1`, set only by the docs
  workflow), so consumers resolve a zero-dependency package.
- `swift/Lint` pins SwiftSyntax 603.0.2 and ArgumentParser 1.8.2. Candidate CI
  builds native arm64 and x86_64 macOS 14 tools, proves arm64 on the builder,
  then downloads the same archive for a hosted Intel proof. The generated
  `skeswa/coglint-plugins` package exposes the binary without putting it in
  Cog's root manifest. [lint.md](../design/lint.md) holds the pins and eager
  fetch evidence.

## Plan-to-task contract

Design docs own behavior. This plan owns milestone scope, exits, and releases.
The task ledger owns work slices, dependencies, checks, and scenario owners.
Update both files when a change crosses that boundary.

Milestone order alone does not create a dependency. Only the table or an
explicit `_Depends:_` edge does. A failed gate gets a small repair task before
it runs again.

| Plan milestone                   | Task ledger                       | Decisions before dependent work                                                            | Closing path                                                                                                                                                                                                           |
| -------------------------------- | --------------------------------- | ------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| M0: Scaffolding                  | [M0 tasks](./tasks.md#m0-tasks)   | `M0-05a` runner topology                                                                   | `M0-10`                                                                                                                                                                                                                |
| M1: Simple correctness core      | [M1 tasks](./tasks.md#m1-tasks)   | `M1-34a`, `M1-15a`, `M1-16a`, `M1-36`                                                      | `M1-33c` host matrix, then `M1-32` release gate                                                                                                                                                                        |
| M2: SwiftUI and Weather          | [M2 tasks](./tasks.md#m2-tasks)   | `M2-17a` read spelling; `M2-07` warning feasibility; `M2-18a` floor-runtime policy         | `M2-16` Weather gate, then `M2-20`; iOS 17 floor coverage was explicitly retired when no reliable runtime was available                                                                                                |
| M3: First async slice            | [M3 tasks](./tasks.md#m3-tasks)   | `M3-08a` never-read async behavior                                                         | `M3-11`                                                                                                                                                                                                                |
| M4: API review and 0.1.0         | [M4 tasks](./tasks.md#m4-tasks)   | `M4-01a` public-name review; `M4-07a` value-first async reads                              | `M4-05b` candidate → `M4-05c` tag → `M4-15` environment repair → `M4-05d` verification → `M4-05e` GitHub Release                                                                                                       |
| M5: Benchmark port               | [M5 tasks](./tasks.md#m5-tasks)   | `M5-05ba` package/metric pins; `M5-05bb` allocator/isolation compatibility                 | `M5-10`                                                                                                                                                                                                                |
| M6: Data-oriented core           | [M6 tasks](./tasks.md#m6-tasks)   | `M6-12a` core/release decision                                                             | `M6-05a` edge gate, then `M6-13` core default, then `M6-12b`; `M6-12c`, `M6-12d`, and `M6-12e` run only when 0.2.0 is approved                                                                                         |
| M7: Async completion and exports | [M7 tasks](./tasks.md#m7-tasks)   | `M7-01a`, `M7-01b`, `M7-01c`, and `M7-01d` ordered/stream decisions                        | `M7-16a` suite → `M7-16b` candidate → `M7-16c` tag → `M7-16d` verification → `M7-16e` GitHub Release; `M7-14c` is non-blocking                                                                                         |
| M8: First-party lint tooling     | [M8 tasks](./tasks.md#m8-tasks)   | `M8-01a`–`M8-01d` surface pins; `M8-01e` selected Channel B after eager-fetch measurements | `M8-15a` suite → `M8-15b` candidate → `M8-15c` tag → `M8-15d` asset release → `M8-15e` verification → `M8-15f` Channel B publication → `M8-18` identity repair → `M8-15g` exact-consumer gate; `M8-19` is non-blocking |
| M9: Shared turn machinery        | [M9 tasks](./tasks.md#m9-tasks)   | `M9-01` profile and route ranking; `M9-18` core, backlog, and release decision             | `M9-16` machinery suite gate, then `M9-17` comparison, `M9-25` and `M9-26` build cost, `M9-18` decision, and `M9-19` closeout                                                                                          |
| M10: Storefront macrobenchmark   | [M10 tasks](./tasks.md#m10-tasks) | `M10-01` workload shape and package boundary; `M10-09` threshold and follow-up decision    | `M10-05` headless results, `M10-07` UI results, `M10-08` core comparison, `M10-09` decision, then `M10-10` closeout                                                                                                    |

## Task bookkeeping

These docs define the work. GitHub issues track live progress.

- One issue per task, titled `Mx-yy: <first sentence>`, labeled with its
  type (`decision`, `infrastructure`, `behavior`, `gate`, `release`, plus
  `non-blocking` where the ledger grants that policy), and assigned to its
  GitHub milestone. The M0–M8 milestones carry each plan-table row: the
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
- A task edit updates its issue in the same change. Add issues for new tasks,
  update blockers, point split parents at their children, and close retired
  tasks as not planned. `mise run tasks:check` checks docs, not GitHub.

## Milestones

<a id="plan-m0"></a>

### M0: Scaffolding

Create the root SwiftPM package, test targets, format tasks, guarded test
wrappers, compile-fail harness, CI skeleton, and task-ledger checker. Record and
enforce the self-hosted runner rules. Exit with formatting, all four host test
legs, release tests, compile-fail fixtures, and ledger checks green.

<a id="plan-m1"></a>

### M1: Simple correctness core

Build the first complete behavior core:

- descriptors, keyed boxes, private sources, and read-only projections;
- named turns, staged writer reads, exact flush order, and escaped-writer traps;
- lazy automatic state, dynamic edges, equality gates, cycles, and peeks;
- reactions, mechanisms, `whenever` scopes, task ownership, and FIFO write-back;
- app, observed, and ephemeral lifetimes with injected test time;
- guarded app assembly and isolated test or preview contexts;
- debug seeding, bounded history, and named diagnostic hooks.

The public behavior suite runs unchanged in all four isolation legs and in a
release build. [M1 tasks](./tasks.md#m1-tasks) own the exact slices and tests.

<a id="plan-m2"></a>

### M2: SwiftUI boundary and Weather

Add lazy Observation boundaries, the `\.cogs` environment, direct per-view
runtime access, tracked reads, peeks, and app-owned bindings. Build the Weather
example with keyed state and mechanisms. Prove exact invalidation, equal-value
silence, untorn multi-value reads, notice order, scene reuse, and UIKit/AppKit
tracking.

Public Observation cannot detect whether a subscript has a current UI reader,
so actions use `peek` and Cog ships no guessed warning. The planned iOS 17.5
nightly was retired because the pinned Xcode could not install that exact
runtime. The normal simulator lane remains the compatibility check.

<a id="plan-m3"></a>

### M3: First async slice

Ship `CogStatus`, required defaults, `Cog<Value>.Async` and
`CogBox<Value, Key>.Async`, synchronous
selectors that return `Work.run`, `.latest`, generation checks, exact
`CogRefresh` results, and safe observed release. Peek and refresh of cold state
create transient demand rather than a lasting lease.

Tests use clocks and continuations for replacement, cancellation, failure,
release, work isolation, and per-turn status. Weather moves its forecast work
to the async box. Ordered policies, streams, and exports wait for M7.

<a id="plan-m4"></a>

### M4: API review, docs, and 0.1.0

Review swift-state-graph, freeze public names, and finish the value-first async
API before release. Add DocC, Getting Started, changelog, consumer smoke tests,
and the missing behavior corners found by the scenario audit.

The release path is candidate → immutable tag → docs and source verification →
GitHub Release. Independent M5 setup may start after candidate approval, but the
M5 gate waits for the published 0.1.0 release.

<a id="plan-m5"></a>

### M5: Benchmark port

Port the standard graph shapes into `CogScenarios` with exact run counts. Build
`swift/Benchmarks` as an isolated package, pin its harness and allocator tools,
record every environment, and add guarded benchmark commands.

Compare inline `AnyHashable`, interned tokens, and generic keyed references on
keyed diamonds and churn. The data selected inline `AnyHashable`. Edge layouts
wait for the arena in M6. [benchmarks.md](./benchmarks.md) owns the numbers.

<a id="plan-m6"></a>

### M6: Data-oriented core

Build arena rows, scalar columns, typed value columns, generation checks, an
explicit settle stack, and lazy boundaries behind the same public API. Compare
linked-pool, prefix-array, and inline edge layouts under the same behavior
suite. The linked pool won.

Run every scenario on simple and arena before any default change. M6 showed
large wide-graph gains but missed the zero-cost goals, so simple stayed the
shipping core and no 0.2.0 release was made. M9 later replaced this decision.

<a id="plan-m7"></a>

### M7: Async completion and exports

Add `.queue`, `.exhaustLatest`, and `.merged` for one-shot work. Add
`Work.stream` under `.latest`, with defined end, failure, cancellation, and
equality behavior. Add independent buffered exports and external Observation
tracking with the documented old-runtime re-arm gap.

Run the full behavior suite and publish 0.3.0. Query caching, persistence sugar,
and a debug-history UI stay open.

<a id="plan-m8"></a>

### M8: First-party lint tooling and 0.4.0

Build the isolated `CogLint` package, syntax classifiers, six rules, reporters,
suppressions, build and command plugins, fixture-built DocC pages, native
artifact bundle, and repository dogfood task.

SwiftPM and Xcode eagerly fetched an unused root binary target, so the root
manifest stays artifact-free. The generated `skeswa/coglint-plugins` sibling
package publishes only after the matching Cog release and docs. Scratch
consumers prove both native variants, cache replay, reporters, and exact-version
plugin use. Publish the complete surface as 0.4.0.

<a id="plan-m9"></a>

### M9: Shared turn machinery and O(changed) notices

Profile call sites before changing more storage. The profile set the work order:

1. Notify changed boundaries instead of scanning every pinned key.
2. Reuse turn objects and buffers until a steady turn allocates nothing.
3. Remove repeated casts, generic metadata lookups, and actor checks.
4. Fuse settle work and stop clean rows early.
5. Measure build cost as well as warm turns.

After shared fixes, arena-specific profiles found dynamic exclusivity and an
erased generic boundary. Safe scalar unchecked access, descriptor caches, and a
stable typed frontier removed those costs. The specialized arena then won every
whole-graph shape and became the only shipping core. `CompactArena` keeps the
same arena without the typed frontier for apps that favor binary size.

M9 changed no public API and made no release.

<a id="plan-m10"></a>

### M10: Storefront macrobenchmark

Add one tested commerce workload under `swift/Storefront` and drive it from both
headless benchmarks and a release SwiftUI app. The standard profile covers
1,200 products, keyed state, async requests, a 16-stage pricing chain, cart
totals, lifetime release, and an eleven-step session. A shadow model checks every
result before timing is accepted.

The first harness mixed control work into timing and had async and dependency
errors. Its results were withdrawn. The corrected headless run is current; the
UI run still needs to be repeated. M10 reports data but adds no threshold,
public API, or release.

## Release process

- Authority: release preparation and publication run entirely in GitHub
  Actions. A maintainer workstation may perform optional developer preflight,
  but it never supplies release evidence or bytes. Human control is review,
  workflow dispatch, queued-run approval, and protected-environment approval.
- History: jj revision descriptions are Conventional Commits and survive
  rebase-only pull-request merges as the authoritative linear release input.
  The required `Conventional Commits` check has no path filter and lints every
  commit in the GitHub PR or push range. `Release-As` is maintainer-only.
- Versioning: Release Please v17.6.0 uses its manifest-driven `simple` strategy.
  `version.txt` is the runtime version source; the private Node documentation
  package remains 0.0.0. Before 1.0, breaking changes and features bump the
  minor, while fixes and performance changes bump the patch. The one-time
  manifest begins at 0.0.0 and bootstraps after
  `16ade4bac358bf1c6f6dbc6e95fad2d467600250`, so the divergent manual 0.4.0 tag
  is neither treated as an ancestor nor replayed.
- Proposal: Release Please maintains a draft release PR, `CHANGELOG.md`, the
  manifest, `version.txt`, and only explicitly marked current-version or
  consumer-pin statements. Published changelog entries and historical design
  evidence are immutable inputs. The release PR stays draft until its exact
  current head passes the complete manual candidate workflow.
- Candidate: manual `swift-ci.yml` requires the release PR number and rejects a
  dispatch at any other SHA. Its hosted revision-range job supplies the
  required `Conventional Commits` context that a repository-token-created
  Release Please PR cannot trigger for itself. The full Actions graph covers
  formatting, host and release tests, both arena configurations, simulator and
  examples, Storefront UI, CogLint integrations, documentation, the ledger,
  benchmark thresholds, an arm64 native build, and hosted Intel verification
  of the same downloaded bytes. The final version/PR-head-qualified artifact
  retains its archive, checksum, and JSON provenance for publication.
- Cog publication: after the draft release PR rebase-merges, Release Please
  force-creates the permanent lightweight bare-semver tag and draft GitHub
  Release. The hosted publisher waits at `cog-release`, then verifies the
  workflow identity, conclusion, PR head, tag/tree equality, version,
  provenance, toolchains, architectures, and checksum before uploading assets,
  titling `Cog <version>`, and publishing. Kotlin remains outside this tag line
  and uses Maven coordinates.
- Docs: a narrow hosted job with only `actions: write` dispatches `docs.yml` at
  the tag after publication, because repository-token-created events do not
  generally start another workflow. DocC and VitePress still merge into the one
  Pages deployment at `https://skeswa.github.io/cog/documentation/cog/`.
- Sibling: after Cog and Docs publish, a human dispatches the
  `coglint-plugins` repository's workflow with the Cog version. Read-only
  preparation verifies the public tag, assets, checksum, and provenance; runs
  the exact tag's generator; and smoke-tests SwiftPM. A `coglint-release`-gated
  job with only sibling `contents: write` re-hashes without executing downloaded
  Cog code, requires sibling `main` unchanged, fast-forwards one conventional
  release commit and creates the matching immutable tag in one atomic,
  non-forced push. A retry accepts an existing tag only when its commit and
  regenerated managed tree are identical. Final public consumption is
  read-only.
- Recovery: a manual `release.yml` dispatch accepts an existing immutable tag
  and merged release PR, rebuilds the complete candidate at that tag in
  Actions, and retries the same protected publisher. Matching partial assets
  are reused, divergent assets fail, and tags are never moved or replaced.
- Serialization: the repository-level release concurrency group, draft release
  PR, immutable tag, and protected publisher admit one Cog publication at a
  time. The sibling concurrency group and unchanged-main proof serialize the
  coupled plugin publication behind it.

## Kotlin boundary

- Swift code lives under `swift/`; a future Kotlin project can live under
  `kotlin/`. Shared checks stay under `tools/`.
- Swift uses bare version tags. Kotlin will use Maven versions.
- Platform tasks and CI filters stay separate.
- A Swift result may inform Kotlin, but it does not decide Kotlin's design.

## Documentation rules

- Settled decisions → exploration §10 and the [README.md](../README.md)
  "Where things stand" snapshot.
- Benchmark results → impl/benchmarks.md; representation choices stay open until
  measured.
- Build, test, and bench commands → `CLAUDE.md` and `AGENTS.md`, in sync.
- New documents → mapped in `docs/swift/README.md` or the root `README.md`.
- New or retired scenarios → [tasks.md](./tasks.md), in the same change:
  every scenario ID stays covered by exactly one task's _Greens:_ line.
- New, split, or reordered tasks → update `_Depends:` and `_Verify:` in the
  same change and keep `mise run tasks:check` green.
- Task changes → update the matching GitHub issues in the same change.
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
  by release publishes nothing; initial and reload failures each produce the
  specified pending and failure turns.
- M4 (`M4-05b` → `M4-05e`): approve a non-mutating candidate, push the tag,
  then prove a scratch iOS 17 app consumes exact 0.1.0 and the DocC site
  deploys before publishing the GitHub Release.
- M5 (`M5-10`): the recorded comparison shows run-count tests green under every
  value-reference candidate; the retained `box[key]` creation path measures
  `mallocCountTotal == 0` and steady turns hold the cost impl/benchmarks.md records;
  value-reference layout numbers are recorded in impl/benchmarks.md before the choice settles.
- M6 (`M6-05a`, then `M6-13` → `M6-12b`): the record proves the M5 set green
  under every arena edge candidate; edge-layout and runtime-comparison numbers
  are recorded before choices settle; the current suite is green on the
  selected implementation. Continue through `M6-12c`–
  `M6-12e` only if `M6-12a` approves 0.2.0.
- M7 (`M7-16a` → `M7-16e`): exact export buffers, subscriber independence,
  stream-before-reaction order, and external post-mutation value tests are
  green; the complete behavior suite passes on the selected core before the
  release sequence starts.
- M8 (`M8-15a` → `M8-15g`): the fixture and integration suites prove all six
  rules, exact locations, suppression, reporters, plugin caching, host-binary
  selection, stable rule URLs, and the selected distribution channel. The
  repository lints clean in production and test target roles; the terminal
  scratch app resolves exactly 0.4.0, runs its matching plugin binary, and
  reaches the matching docs.
- M10 (`M10-10`): the Storefront workload's correctness and shape suites green;
  the five headless cuts registered and reporting under the specialized default
  and compact arena; the release UI performance suite executing on the pinned
  simulator; linter and formatter clean; `impl/benchmarks.md` carrying the
  measurements, their environment, and the workload's stated limits.
- Always: formatting and task-ledger checks clean; path-filtered CI green.

## Open checks

- Measure benchmark noise if the Mac mini moves from bare metal to a VM.
- Recheck the benchmark tool pins when Swift or Xcode changes.
- If SwiftPM stops re-reading environment settings, use
  `--manifest-cache none`.
- Move simulator checks out of pull requests if they become too slow.
- Public Observation cannot tell whether a read has a UI consumer. Cog cannot
  give an exact missing-consumer warning until Apple adds that signal.
- iOS 17 floor testing is retired. Restore it only if Actions can install,
  boot, and keep a pinned runtime in a repeatable way.
