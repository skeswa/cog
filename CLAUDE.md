# CLAUDE.md

This file guides Claude Code when working in this repository. `AGENTS.md`
mirrors it for other coding agents; keep the two files in sync.

## What this is

The repository for **Cog**, a fine-grained state-management project for native
mobile UI. Cog consists of:

- a Swift library for SwiftUI on iOS, built over `@Observable` at the boundary
  with one app-wide MainActor-confined dependency graph inside; and
- a Kotlin library for Jetpack Compose on Android with one app-wide graph.

The Swift library is implemented.
<!-- x-release-please-start-version -->

The current published Swift release is 0.5.0.
<!-- x-release-please-end -->

The specialized arena is the shipping default, and the Storefront
macrobenchmark's open decisions continue against `docs/swift/impl/scenarios.md`.
Kotlin has a complete first design but no implementation. The canonical
current snapshots live in `docs/swift/README.md` and `docs/kotlin/README.md`;
keep status there rather than copying it into this instruction file.

## Layout

- `README.md` — consumer-facing project overview, shared principles, platform
  status, installation, and documentation entry points.
- `CONTRIBUTING.md` — contributor setup, verification, test organization,
  documentation obligations, and the Jujutsu workflow.
- `SECURITY.md` — supported releases and private vulnerability reporting.
- `docs/maintainers/changes.md` — the authoritative Conventional Commit
  authoring, validation, range-selection, and release-input process.
- `Package.swift` — the SwiftPM manifest. The package root is the git root;
  every Swift target reaches under `swift/` through an explicit `path:`. The
  manifest reads the isolation selectors and public arena trait described
  under "Commands" below.
- `swift/Sources/` — `Cog` (the shipping library), `CogTesting` (the
  isolated-context factory for tests and previews), and `CogScenarios` (the
  shared scenario graphs, exported as the non-API `_CogScenarios` product).
- `swift/Tests/` — `CogTests` (correctness), `CogScenarioTests` (run counts),
  and `CogBoundaryTests` (the Observation and SwiftUI boundary). Inside
  `CogTests`, public behavior proofs live under `Scenarios/<PREFIX>/` in
  `...ScenarioTests.swift` files named for their raw IDs; internal proofs live
  separately under `Infrastructure/<seam>/` in
  `...InfrastructureTests.swift` files and green no scenario.
- `swift/CompileFail/` — expected-failure fixtures, deliberately outside every
  SwiftPM target, type-checked in one batched pass per build configuration.
  Most fixtures check against the debug modules; fixtures declaring
  `// configuration: release` check against the release modules to prove
  debug-only API stays absent from release builds.
- `swift/Benchmarks/` — the benchmark workspace container, not a SwiftPM
  package. Its `README.md` is the short map to the independently resolvable
  runner, workload, runtimes, verification suite, and application driver.
- `swift/Benchmarks/Runner/` — the **separate** `cog-benchmarks` SwiftPM
  package, depending on the root and Storefront packages by path so its
  benchmark harness and allocator backend can never enter the dependency graph
  a consumer or benchmark application resolves. Run `swift package benchmark`
  from this directory. Its `README.md` records the pinned tool matrix and the
  MainActor isolation shim; `Probes/` holds the measurements those pins rest
  on; `Thresholds/` holds committed gates. Unlike the root package, its
  `Package.resolved` is committed. `Benchmarks/CogCore/`,
  `Benchmarks/RuntimeComparison/`, and `Benchmarks/Storefront/` are three
  executable targets. Their immediate parent must keep the literal name
  `Benchmarks`: that doubled name is the pinned harness's hard discovery rule.
- `swift/Benchmarks/Storefront/` — the Storefront macrobenchmark: not an
  example app but the suite's one _application-shaped_ measurement, in which
  four state-management runtimes run one identical eleven-phase commerce
  session. Its `README.md` is the entry point for the four runtimes, shared
  workload, agreement gate, and run commands.
- `swift/Benchmarks/Storefront/Workload/` — the **separate**
  `cog-storefront-workload` SwiftPM package holding the runtime-neutral domain
  model, deterministic fixtures, heavy kernels, sixteen-policy pricing ladder,
  scripted async service, eleven-phase trace, and independent shadow model. It
  has no package dependencies and its sole library target depends on nothing at
  all, not even Cog. Every runtime and both the headless and SwiftUI drivers use
  this exact workload.
- `swift/Benchmarks/Storefront/Runtimes/CogRuntime/` — the **separate**
  `cog-storefront` SwiftPM package holding the 53 Cog declarations, domain
  operations, assembly mechanism, and `CogStorefrontRuntime` adapter. It
  depends only on the root and the neutral workload. The directory avoids the
  bare name `Cog`, which would collide with the root package's SwiftPM identity.
- `swift/Benchmarks/Storefront/Runtimes/Observation/` — the **separate**
  `cog-storefront-observation` SwiftPM package holding the two plain-Swift
  comparison runtimes for that
  workload: `StorefrontObservationRaw`, the recompute-on-every-read floor, and
  `StorefrontObservationMemo`, honest hand-written memoization. It depends on
  the workload by path and on nothing else. The two ports are separate targets
  so it is a compile error for the raw port to reach the memo port's cache.
- `swift/Benchmarks/Storefront/Runtimes/StateGraph/` — the **separate** `cog-storefront-state-graph`
  SwiftPM package holding the swift-state-graph port of the same workload,
  pinned `exact: "0.28.0"`, with its committed `Package.resolved`, its
  `API-NOTES.md` recording every measured library behavior the port rests on,
  and the throwaway `Probes/APIBehavior/` package that measured them. It is a package of its
  own because SwiftPM hands a package's dependencies to everyone who resolves it:
  an `@Observable` comparison app must not resolve swift-state-graph and its
  macro toolchain.
- `swift/Benchmarks/Storefront/Verification/` — the **separate**, test-only
  `cog-storefront-verification` SwiftPM package. It is the only package that
  resolves all four runtimes, so it owns the cross-runtime agreement and build-
  shape gates without weakening isolation among the runtime packages.
- `swift/Benchmarks/Storefront/Apps/Cog/` — the SwiftUI benchmark
  application driving the Cog port of that workload, whose `StorefrontUITests`
  target measures launch, scrolling, search, navigation, and cart interaction
  in release through XCUIAutomation. A hand-written objectVersion-77 Xcode
  project referencing the root package and the workload package by relative
  path. It lives beside the workload rather than under `swift/Examples/`
  because it is a benchmark driver, not an example. Later phases add sibling
  apps under `Apps/` for the comparison runtimes.
- `swift/Lint/` — the **separate** `CogLint` SwiftPM development package. Its
  package-only `CogLintCore` and `CogLintFixtures` targets, `coglint`
  executable, fixture-backed DocC generator, and tests own the exact
  swift-syntax and swift-argument-parser pins without exposing them to a Cog
  consumer. Its committed `Package.resolved` fixes those revisions, and its
  scaffold test asks SwiftPM to prove the root dependency graph remains empty.
- `swift/Examples/` — three hand-written objectVersion-77 Xcode example apps
  that reference the root package by relative path: `Weather/`, the worked
  async and mechanism example; `TodoMVC/`, the classic fine-grained keyed-state
  and persistence example; and `Trails/`, the state-driven navigation,
  deep-linking, and restoration example.
- `tools/` — pinned Node tooling: `swift-test.mjs`, `swift-lint-test.mjs`,
  `swift-simulator-test.mjs`, `storefront-test.mjs`,
  `storefront-runtimes-test.mjs`, `storefront-state-graph-test.mjs`,
  `storefront-agreement-test.mjs`, `storefront-ui-test.mjs`,
  `check-compile-fail.mjs`, `check-changes.mjs`, and `check-workflows.mjs`,
  plus shared test guards, the checkers' own fixture suites
  (`test-workflows.mjs`, `test-changes.mjs`), and `fixtures/`.
- `.github/workflows/` — `swift-ci.yml` (the complete host, simulator,
  example, benchmark, documentation, native-artifact, and exact-release-PR
  candidate graph), `conventional-commits.yml` (the required revision-history
  check), `release.yml` (Release Please, protected publication, recovery, and
  the explicit Docs dispatch), `docs.yml` (the DocC archive on the mini, the
  VitePress site on a hosted runner, merged and published to GitHub Pages), and
  `markdown.yml` (Oxfmt and the workflow-contract check on GitHub-hosted
  ubuntu).
- `mise.toml`, `.oxfmtrc.json`, `.swift-format`, `.gitignore`, `LICENSE` —
  task definitions, formatter configuration, and the license.
- `docs/design.md` — the normative state model and vocabulary shared by Swift
  and Kotlin. Platform documents refine it without silently overriding it.
- `docs/history.md` — the nonnormative lineage from the original Dart and
  Flutter design, including the ideas retained, revised, or rejected.
- `docs/swift/` — living Swift documents. Start with `README.md`, the map.
  Design docs live in `docs/swift/design/`: `exploration.md` covers the core
  architecture and API; `mechanisms.md` covers mechanisms — the assembly-registered
  home for every side effect — and background work;
  `rx.md` maps Rx concepts; `design/perf.md` covers the cost order, the
  data-oriented implementation, and the measurement plan — design only, since
  the recorded results live under `impl/`. Implementation docs live in
  `docs/swift/impl/`: `scenarios.md` is the test-scenario tree, the single
  census of promised behavior; `architecture/` explains the implemented
  runtime from public references down to arena rows; `impl/perf.md` is the
  performance record, organized around what a reader wants to know — what the
  current build measures, where the gaps in the implementation are, which
  trade-offs were taken, and which improvements have not been made yet — with
  every number carrying the environment that produced it; and
  `perf-history.md` is the frozen record of retired numbers, superseded
  comparisons, and the decisions they settled. Because `perf.md` now names two
  different documents, always path-qualify a reference to one: `design/perf.md`
  is the design, `impl/perf.md` is the record.
- `docs/kotlin/` — living Kotlin and Jetpack Compose design documents. Start
  with `README.md`. `exploration.md` covers the core architecture and API;
  `example.md` gives a full worked feature; `effects.md` covers effects and
  background work; `flows.md` maps Flow and reactive concepts; `perf.md`
  covers the runtime candidates and benchmark plan.
- `docs/.vitepress/` — the VitePress site that publishes `docs/`. `config.mts`
  holds the site configuration, `navigation.mts` the hand-written sidebar (it
  mirrors the reading order in `docs/swift/README.md`, which stays the source of
  truth), `mermaid-markdown.mts` the fence transform, and `theme/` a light
  extension of the default theme. `package.json` at the repository root carries
  its dependencies.
- `docs/maintainers/` — operational runbooks. `ci.md` owns the Xcode pin,
  self-hosted runner topology, hosted fork lane, workflow security record, and
  the open operational questions; `releasing.md` owns the Swift release policy
  and turns it into an Actions-only candidate, protected publication,
  recovery, documentation, and sibling checklist.

## Commands

Every command is a mise task defined in `mise.toml`, which is authoritative;
`mise tasks` prints the current list. mise cannot pin Xcode, so the tested
Xcode version lives in `docs/maintainers/ci.md`.
A full Xcode is required, not the Command Line Tools alone: CLT can build and
lint but `swift test` fails there with `no such module 'Testing'`.

Formatting is split per language under two umbrellas, and either leg can be
run alone:

- `mise run fmt` — `fmt:md` (Oxfmt over Markdown, JSON, YAML, and JavaScript)
  and `fmt:swift` (`swift format --in-place`).
- `mise run fmt:check` — `fmt:check:md` and `fmt:check:swift`
  (`swift format lint --strict`). Writes nothing.

`.oxfmtrc.json` excludes every `swift/Sources/**/*.docc/**` catalog file. DocC
markdown is not ordinary markdown: Oxfmt rewrites its double-backtick
symbol links into single-backtick code spans, which silently turns every
documentation link into plain text.

It also excludes `CHANGELOG.md`, whose layout is generated by the pinned
Release Please changelog writer. The release-configuration test owns its
published-section, bootstrap, and required-entry invariants; a formatter must
not make the release PR dirty after that generator has produced it.

Root-package tests go through `tools/swift-test.mjs`, never `swift test`
directly:

- `mise run test` — the default isolation leg, serialized so benchmark-sized
  graph scenarios cannot starve time-bounded actor tests.
- `mise run test:matrix` — all four isolation legs, serialized within each leg.
- `mise run test:arena-configurations` — prove the unset package compiles the
  specialized arena and run the complete behavior suite through both that
  shipping default and the public `CompactArena` opt-out, serialized so
  benchmark-sized graph scenarios cannot starve time-bounded actor tests.
- `mise run test:release` — the default leg in release configuration, serialized.
- `mise run api:check [baseline]` — compares the supported `Cog` and
  `CogTesting` public APIs with the newest semantic-version release tag, or an
  explicit baseline. The non-API `_CogScenarios` product is deliberately
  excluded.
- `mise run test:simulator` — only `CogBoundaryTests` on the latest iOS
  simulator. Set `COG_SIMULATOR_DESTINATION` to override the destination.
- `mise run test:compilefail` — type-checks every fixture in
  `swift/CompileFail/` in one batched `swiftc -typecheck` pass per build
  configuration (debug, plus release for `// configuration: release`
  fixtures), failing both when a fixture misses its expected diagnostic and
  when it stops failing.
- `mise run test:lint` — run the separate `swift/Lint` package tests. This
  wrapper enumerates tests before every run and requires a nonzero executed
  count from its own xUnit report. Extra arguments pass through, as in
  `mise run test:lint --filter LINT-02`.
- `mise run lint:swift` — first run the guarded CogLint suite, then lint the
  root library, the Storefront workload and Cog runtime packages, the two
  comparison-runtime packages, the three example apps, and the Storefront
  benchmark app's production sources with production rules, and
  every tracked test target source with the explicit test-role primitive
  exemption. The Storefront Cog runtime is linted like application code on purpose:
  it is the worked example of what a large Cog app looks like, and a benchmark
  that broke the conventions it exists to measure would be measuring the wrong
  thing. The comparison-runtime packages are linted too even though they contain
  no Cog, so that a Cog symbol appearing in a port that is supposed to be free of
  one is caught rather than assumed absent; every CogLint rule keys on an actual
  Cog declaration, so Cog-free source produces no diagnostics. The state-graph
  port's `Probes/APIBehavior/` package is a named input for the same reason even though it is
  a throwaway measurement executable outside every target: a directory no linter
  inspects is how a convention violation stays unnoticed, and that is exactly how
  the probe reached `main` with a class that declared no `nonisolated deinit`.
  `swift/Benchmarks/Storefront/Verification/Tests`, which holds the cross-runtime
  agreement suite, is a test-role input on that same argument; Runner is not,
  because the harness sources are measurement apparatus rather than a worked
  example. Empty Xcode-created target directories are not command inputs; CogLint
  continues to reject any named input that does not exist.
- `mise run build:lint-artifact [version]` — build native macOS 14 `arm64` and
  `x86_64` CogLint executables, assemble the release artifact bundle, and
  record its SwiftPM checksum. With no argument it reads `version.txt`.
- `mise run test:lint-artifact` — rebuild the artifact and prove SwiftPM
  selects and executes each exact metadata variant under arm64 and Rosetta.
  Candidate CI splits the same proof without rebuilding the archive: append
  `-- --host arm64` on its pinned-Xcode builder, then append
  `-- --from-archive --host x86_64` after downloading it on the pinned Xcode
  26.3/17C529 Intel host.
- `mise run test:lint-build-tool-plugin` — apply the local artifact through
  the build-tool plugin in scratch SwiftPM and Xcode consumers, then prove an
  unchanged rebuild replays identical diagnostics from each plugin cache.
- `mise run test:lint-command-plugin` — invoke the command plugin in a scratch
  consumer and prove byte-identical bare-CLI behavior under both target roles
  and all three reporters.
- `mise run build:lint-distribution` — generate the version-coupled Channel B
  `CogLintPlugins` package from the checked-in plugin sources and current
  artifact checksum. Its version defaults to `version.txt`; optional named
  arguments override version, output, checksum, and artifact URL.
- `mise run test:lint-distribution` — prove an ordinary Cog consumer resolves
  and builds without lint sources or an artifact fetch, while an unused
  Channel B opt-in retains SwiftPM’s measured eager-fetch behavior.
- `mise run build:lint-documentation` — regenerate all seven checked-in CogLint
  DocC articles from their executable fixture corpora.
- `mise run test:lint-documentation` — regenerate into scratch space, require
  byte-for-byte fixture parity, build the DocC archive, and verify every
  permanent diagnostic URL has both its static HTML route and data payload.

- `mise run bench` — run the Cog benchmarks from `swift/Benchmarks/Runner` in release.
  Extra arguments pass through, as in `mise run bench --filter perf-01-steady-turn`.
- `mise run bench:compact` — run the same benchmark package with its
  `CompactArena` trait, forwarding that public trait to Cog. Extra arguments
  pass through, so Storefront's five compact cuts are
  `mise run bench:compact --filter 'perf-15-storefront-.*'`.
- `mise run bench:baseline:update [name]` — record a benchmark baseline in
  `swift/Benchmarks/Runner` together with the environment that produced it (Xcode,
  Swift, harness and interposer versions, architecture, host, allocator
  backend). Defaults to `local`.
- `mise run bench:baseline:check [name]` — refuse to compare across
  environments, assert the allocation witness still reports a non-zero malloc
  count, then check the run against that baseline. Baselines live in the
  git-ignored `swift/Benchmarks/Runner/.benchmarkBaselines/`; numbers meant to
  outlive a session go in `docs/swift/impl/perf.md`.
- `mise run bench:thresholds:check` — assert the allocation witness is live,
  require every gated benchmark and its committed static threshold, then
  enforce PERF-06's exact p90 zero-allocation result and PERF-10's one-sided
  wall-clock ceilings. This is the benchmark gate CI runs on the pinned mini.
- `mise run bench:thresholds:sentinel` — run a real PERF-10 workload against a
  temporary impossible threshold and pass only when the gate rejects it as a
  regression.

The Weather, TodoMVC, and Trails example apps and the Storefront benchmark
app use the same pinned Xcode as the library:

- `mise run build:weather` — build the Weather app for a generic iOS
  Simulator destination without launching one.
- `mise run build:todomvc` — build the TodoMVC app for a generic iOS Simulator
  destination without launching one.
- `mise run build:trails` — build the Trails app for a generic iOS Simulator
  destination without launching one.
- `mise run build:storefront` — build the Storefront benchmark app, whose
  Xcode project lives at `swift/Benchmarks/Storefront/Apps/Cog/`, for a
  generic iOS Simulator destination without launching one.
- `mise run test:storefront-ui` — run `StorefrontUITests` in **release** on a
  pinned iOS simulator, and read the result bundle back to require a nonzero
  executed count. Release rather than debug because Apple's performance-test
  guidance is explicit that a measured run builds for testing with the Release
  configuration and the debugger, code coverage, and runtime diagnostics off;
  the scheme carries those settings. Set `COG_STOREFRONT_DESTINATION` to
  override the destination, which local exploration may want and CI must not.

Each Storefront package has a guarded wrapper with its own scratch path:

- `mise run test:storefront` — run the guarded
  `swift/Benchmarks/Storefront/Workload` package tests: the neutral workload's
  profile shape and eleven-phase shadow trace.
- `mise run test:storefront-cog` — run the guarded
  `swift/Benchmarks/Storefront/Runtimes/CogRuntime` package tests: the Cog
  declaration census and runtime against the shared shadow model.

- `mise run test:storefront-runtimes` — run the guarded
  `swift/Benchmarks/Storefront/Runtimes/Observation` package tests: the two
  plain-Swift `@Observable` ports against the shared shadow model and each
  other.
- `mise run test:storefront-state-graph` — run the guarded
  `swift/Benchmarks/Storefront/Runtimes/StateGraph` package tests: the swift-state-graph port against
  the same shadow model.
- `mise run test:storefront-agreement` — run the guarded cross-runtime agreement
  suite, the strongest gate the macrobenchmark has. It drives all four runtimes
  through the identical eleven-phase trace and requires them to agree exactly
  with each other and with the shared shadow on what is on screen, the rendered
  checksum, the settled suggestions, the order total, and a zero outstanding
  request count — then asserts that the declared semantics admitting no
  variation really are invariant and prints the ones that legitimately differ.
  Without it a fast number might just be a wrong number. The suite lives in
  `swift/Benchmarks/Storefront/Verification/Tests/StorefrontAgreementTests`
  because that is the only package that can see all four runtimes. It also owns
  the manifest build-shape assertions. Its scratch path is separate from the one
  `mise run bench` uses so correctness and measurement runs do not invalidate
  each other.
- `mise run test:storefront-all` — run all five Storefront suites together. Use
  it before recording any cross-runtime number: a comparison is only meaningful
  when every runtime in it is green in the same revision.

Extra arguments pass straight through, as in
`mise run test --filter 'DECL-01|ONE-05'`. **Never run a filtered
`swift test` yourself.** SwiftPM exits 0 when `--filter` selects nothing, so a
raw filtered run can report a green for work it never ran. The wrapper guards
twice — it enumerates the built tests before the run and checks the
authoritative executed-test count after it — and gives each leg and
configuration its own scratch path.

The isolation matrix is {MainActor-default, nonisolated} × {NNBD on, off},
selected through `COG_TEST_ISOLATION` and `COG_TEST_NNBD`. Each leg is also a
wrapper mode of its own — `mainactor-nnbd-on`, `mainactor-nnbd-off`,
`nonisolated-nnbd-on`, `nonisolated-nnbd-off` — which CI uses to run one leg
per job. `COG_TEST_MANIFEST_CACHE=none` is an escape hatch for a stale
manifest cache; it is not needed today.

The specialized arena, inline `AnyHashable` keyed references, and linked edge
pool are the sole retained runtime representations. The rejected generic and
interned value references, prefix and inline edge layouts, and simple core live
only in the benchmark and optimization records. Their former environment
selectors (`COG_TEST_VALUE_REFERENCE_LAYOUT`, `COG_TEST_EDGE`,
`COG_TEST_CORE`, and `COG_TEST_ARENA_SPECIALIZATION`) are manifest hard errors
so stale comparison commands cannot silently measure the shipping build. A
final application can explicitly trade speed for binary size with the
non-default `CompactArena` package trait, which keeps the arena and linked edge
pool but suppresses the typed frontier. Because traits are additive, reusable
libraries should not force that application-level choice on their consumers.

The published site at `skeswa.github.io/cog/` has two halves, built by two
toolchains and merged into the one GitHub Pages deployment a repository gets:

- `mise run docs:api` — builds the DocC archive into
  `.build/docs/Cog.doccarchive`, transformed for static hosting under
  `--hosting-base-path cog`. This is a task of its own because swift-docc-plugin
  is env-gated behind `COG_DOCC=1` so ordinary consumers resolve this package
  with no dependencies. It deletes the `Package.resolved` the gated resolve
  writes; that file carries the plugin's pins and must never be committed, and
  `docs.yml` fails the build if one survives. It also passes
  `--experimental-transform-for-static-hosting-with-content`, which bakes each
  page's title, description, and article text into its own HTML file instead of
  emitting one identical app shell for every route — so the reference is
  readable and linkable without JavaScript. That is a legibility choice, not a
  styling one: DocC keeps its own appearance deliberately, and nothing tries to
  make it resemble the VitePress half.
- `mise run docs:build` — builds the VitePress site over `docs/` into
  `docs/.vitepress/dist`. Its `base` must agree with the DocC
  `--hosting-base-path`.
- `mise run docs:dev` — serves that site with hot reload. `mise run docs:preview`
  serves the built output, without the DocC half.
- `mise run docs` — runs both and merges them into `.build/docs-site` through
  `tools/assemble-docs-site.mjs`.

All four VitePress-side commands need `npm ci` to have run first. The docs site
is the only thing in this repository with a dependency tree; the Swift package
still resolves with none.

The merge is an overlay, and `tools/assemble-docs-site.mjs` explains why it is
safe: DocC owns `documentation/`, `data/`, `css/`, `js/`, and `img/`, VitePress
owns `assets/` and its route directories, and the only file VitePress takes over
is the root `index.html` — which costs nothing, because the archive was
transformed for static hosting and every documentation route already has its own
`index.html`. `skeswa.github.io/cog/documentation/cog/` therefore keeps
resolving, which matters because the root `README.md` and the release runbook
link to it by name. The script asserts those exact routes survived and fails
rather than publishing a site that 404s its own API reference.

Document and workflow checks, each of which runs its own fixture suite first
because a broken checker cannot validate anything:

- `mise run workflows:check` — validates the GitHub Actions hardening
  contract over `.github/workflows`, including the exact hosted write jobs,
  protected environments, candidate identity, provenance, recovery, docs
  dispatch, action pins, and sibling-publication shape. Each write grant is a
  named job/scope entry in `PERMISSION_EXCEPTIONS`, applies only on a
  GitHub-hosted runner, and is fixture-tested on both sides.
- `mise run changes:check` — runs Commitlint 21.2.1 over non-empty jj
  descriptions in `main..@`; on GitHub, the same checker authoritatively lints
  every commit in the PR or push range. Its fixtures cover Git and jj ranges,
  breaking changes, Release Please secondary messages, and maintainer-only
  `Release-As`.

Every change must leave `mise run fmt:check` green.

## Version control

- This is a Jujutsu (`jj`) repository colocated with git. Do day-to-day
  version control with `jj` — `jj st`, `jj diff`, `jj commit`,
  `jj bookmark`, `jj git push` — not `git add`/`git commit`. There is no
  staging area; the working copy is itself a commit. `main` is a jj
  bookmark tracking the GitHub default branch.
- Make all changes as small, well-described revisions: one logical change
  per revision, never a batch of unrelated edits. Describe each revision
  when it lands (`jj commit -m`, or `jj describe` on the working copy) as a
  Conventional Commit: `type(optional-scope): imperative summary`, with `!`
  and `BREAKING CHANGE` when appropriate. Accepted types are `build`, `chore`,
  `ci`, `docs`, `feat`, `fix`, `perf`, `refactor`, `revert`, `style`, and
  `test`; `Release-As` is maintainer-only. Run `mise run changes:check`. If the
  working copy has grown past one logical change, split it (`jj split`) rather
  than describing a grab bag. Paired obligations — `CLAUDE.md` with
  `AGENTS.md`, a new command with its entry in both — belong together in the
  one revision that makes them true.
- Git remains because the outside world consumes it: SwiftPM resolves the
  package from the git repo GitHub serves and CI checks out git. Pull requests
  rebase-merge so jj revision descriptions remain the authoritative linear
  history Release Please reads. Release Please alone creates the permanent
  lightweight bare-semver tags; no release step runs from a maintainer
  workstation. Ordinary source pushes continue through `jj git push`.

## Project principles

Every design and implementation choice should preserve four rules:

1. Cog should feel simple to use, read, and reason about.
2. Every state read should be correct.
3. Cog should minimize runtime overhead without weakening the other rules.
4. Cog state should be singular: one running app has one authoritative graph,
   each mutable fact represented in Cog has one writable source in it, and
   screens or features do not create state islands or mirror sources.

For Swift, a correct normal read uses the latest completed turn and settles
every dependency needed for that value. A `Writer` read during a turn sees
that turn's staged source values. Async value reads are total: they return
the last accepted success, resting on the declaration's default until one
exists. Async uncertainty stays explicit in `CogStatus`, read through the
opt-in `status` lens. Production uses one app-wide `Cogs`.

For Kotlin, a correct normal read also uses the latest completed turn and
settles every dependency it needs. A writer read sees its turn's staged source
values. A grouped read and a Compose read see one consistent snapshot. Async
uncertainty stays explicit in `CogPhase`.

Kotlin production uses one process-wide `CogStore`. Screens and
ViewModels use that singleton and never create or close it.

Tests and previews are separate app runtimes. Each may create one isolated
`Cogs` or `CogStore`, but must not fragment state inside
that runtime.

## Conventions

- **Suffix Swift state declarations by shape.** Name every keyless value
  reference `thingCog`, with `Cog` as the final word; this includes manual,
  automatic, async, and read-only projection declarations. Name every box
  `thingCogs`, with plural `Cogs` as the final word. Put narrower qualifiers
  before the suffix (`weatherServiceLoaderCog`, `weatherReportDraftCogs`).
  The app runtime remains the ordinary local `cogs`, and ordinary values read
  from the graph receive normal domain names without either suffix.
- **Underscore every manual cog; its projection takes the clean name.** Every
  manual declaration begins with a leading underscore
  (`private let _temperatureCog = Cog<Int>.Manual { 0 }`), whether or not it is
  projected. When the state is published, the `.readOnly` projection is named
  exactly the source's name without the underscore
  (`let temperatureCog = _temperatureCog.readOnly`), so the clean name is the
  one the rest of the app reads. The retired `Source` qualifier
  (`temperatureSourceCog`) must not reappear. Spell file-scope declarations
  `private`, not `fileprivate` — swift-format rewrites file-scoped
  `fileprivate` to `private`. CogLint's `manual-cog-underscore` rule enforces
  both halves.
- **Unwrap Swift state reads into domain locals.** In application code and
  user-facing examples, bind each value-producing `c[...]`, `cogs[...]`, or
  status/peek read to a local before using it. Name that local by removing the
  declaration's final `Cog` or `Cogs`. For a status read, write
  `let forecast = cogs.status[forecastCog]`; do not add a `forecastStatus`
  suffix even though its type is `CogStatus`. Read status fields from that
  local. Creating it observes no field by itself, so SwiftUI still tracks only
  the fields the body uses. This rule applies in views, selectors, reactions,
  and operations. Writer lvalues, commands that accept a value reference, and
  low-level tests isolating an exact read expression need not invent a local.
- **Resolve `Cogs` in every SwiftUI consumer.** The app or scene root retains
  the one runtime and installs it with `.cogEnvironment(cogs)`. Every `View`
  that interacts with Cog declares `@Environment(\.cogs) private var cogs`
  itself; a view never accepts, stores, or forwards `Cogs` through an
  initializer. Intermediate views pass domain values and identities only.
  Tests and previews host views under the same environment modifier. Explicit
  `Cogs` parameters remain appropriate at non-view composition boundaries such
  as isolated test harnesses; side effects register as mechanisms in the
  assembly call rather than through any later installation.
- **Wrap every primitive in a named op.** `turn` and `refresh` are how the
  graph is asked to do something, not what an app calls the asking. Application
  code — a view action, a button, a mechanism — calls a domain verb from a
  `CogOps` extension (`cogs.refreshForecast(for: zip)`), never the primitive
  inline. This keeps the declaration a call site resolves to in the state layer
  with the rest of it, and it applies to `refresh` for the same reason it
  applies to `turn`: both are demands on the graph, and neither is domain
  vocabulary.
- **Read flatly; never repackage reads into a projection type.** A view that
  needs several values reads each one on its own line and binds it to a domain
  local, however many there are. Do not gather them into a struct — not one
  built by an initializer taking `Cogs`, and not one built by a `Cogs`
  extension. A projection type adds a layer that must be read to know what the
  view depends on, invites being stored or passed onward, and buys nothing:
  reads in one `body` already come from one settled turn, and each already
  registers on its own so unrelated turns invalidate nothing. If a value is
  genuinely automatic rather than merely read together, declare an automatic cog and
  read that flatly too.
- **Put initial app state in a mechanism's `operate`, not in the app entry
  point.** `operate` runs inside assembly, so its writes settle before
  `assemble` returns and no watcher observes the pre-initial value on the
  way past. The app entry point assembles and retains the runtime; it does not
  write to it. A test arranges the same starting world by passing the same
  mechanism to `Cogs.forTesting(mechanisms:)`. `forTesting`'s `seeding:`
  closure is not the production counterpart of this: it exists to install
  values without a turn, before anything watches, which is a testing need.
- **Make Swift source explain its contracts.** Every Swift source file and
  every internal-or-higher declaration needs substantive documentation
  comments. Explain the semantics a maintainer cannot infer from a signature:
  identity and storage, ownership and lifetime, actor or executor isolation,
  turn and settlement ordering, observation and dependency tracking, and
  cancellation or race invariants where they apply. Document private helpers
  and fields when correctness depends on a non-obvious invariant. Explain why;
  do not restate syntax or add boilerplate to obvious locals. A broad comment
  audit must use emitted symbol graphs to find declaration gaps and
  mechanically confirm that the resulting source diff is comment-only.
- **Spell a fail-fast trap `fatalError`, never `preconditionFailure`.** The
  standard library drops `preconditionFailure`'s message under `-O`: the
  process still traps, but with no explanation, so a scenario promising "a
  clear error … in release builds" would be unprovable. Measured — under
  `-Onone` both print; under `-O` only `fatalError` does. An exit test for a
  trap should assert on the child's `standardErrorContent`, not merely its
  exit status, or it cannot tell a clear error from a bare trap.
- **A scenario test never uses `@testable import Cog`.** Tests that own a
  scenario ID prove it through the public API and `CogTesting` only. The
  behavior suite must not observe representation details: it was the common
  proof while the retained layouts were selected and remains the proof for the
  public `CompactArena` trait. Reach for `@testable` only in infrastructure
  tests, which green no scenario.
- **Give every class an explicit `nonisolated deinit`.** With
  `.defaultIsolation(MainActor.self)`, a synthesized `deinit` is
  main-actor-isolated, which is wrong twice over. On a **generic** class it is a
  build problem: Swift 6.3.0 and 6.3.3 both crash the optimizer on it in release
  configuration. Debug builds are fine, so `mise run test:matrix` will not catch
  it — only `mise run test:release` will. On **any** class it is also a cost: an
  isolated `deinit` compiles to `swift_task_deinitOnExecutor`, so every
  deallocation asks the concurrency runtime which executor it is on. `M9-01`
  measured that at about an eighth of a steady turn. This applies to states,
  boxes, descriptors, async state, turn objects, edges, and arena storage
  alike.
- **A `deinit` that must touch the graph is spelled `isolated deinit`, and
  its class must not be generic.** A written `deinit` is nonisolated unless it
  says otherwise, so it cannot call a MainActor-isolated method at all — the
  compiler rejects it outright, which is the opposite failure from the
  synthesized case above and is caught at build time rather than in release.
  `ReactionToken` is the worked example: non-generic, so it can take the
  isolation, and the isolation is what lets a handle released on the MainActor
  clean up synchronously instead of hopping. Do not "fix" one of these two
  spellings into the other; they solve opposite problems.
- **Keep platform designs separate.** Cross-platform invariants and vocabulary
  live in `docs/design.md`. Swift and Kotlin documents own their platform APIs,
  runtime mechanics, and framework integration; do not copy a platform choice
  across without recording a decision for the receiving platform.
- **Preserve shared Swift section numbering.** The companion docs were split
  from `exploration.md`: `mechanisms.md` is §6 and `rx.md` is §5.4. A reference
  such as “§6.4” resolves in `mechanisms.md`. Do not renumber these sections.
- **Preserve shared Kotlin section numbering.** The Kotlin companion docs use
  the same map: `effects.md` is §6 and `flows.md` is §5.4.
- **Dated files are frozen; undated files are living.** Living design docs use
  short lowercase names and carry an authorship date below the title.
- **Map new docs.** Add shared docs and new platform doc sets to the root
  `README.md`. Add new Swift docs to `docs/swift/README.md` and new Kotlin docs
  to `docs/kotlin/README.md`.
- **Do not re-litigate settled decisions.** The Swift snapshot is in
  `docs/swift/README.md` under “Where things stand.” The full settled/open
  ledger is `docs/swift/design/exploration.md` §10. The Kotlin snapshot and
  ledger are
  in `docs/kotlin/README.md` and `docs/kotlin/exploration.md` §10. Designs are
  hardened through `/vette` reviews. When the user accepts a decision from a
  review, update both records for that platform. Track real open questions in
  §10.
- **Keep performance claims benchmark-gated.** Both design performance
  documents — `docs/swift/design/perf.md` and `docs/kotlin/perf.md` — defer
  representation choices to benchmarks. Do not mark them settled without
  measurements; the measurements themselves belong in
  `docs/swift/impl/perf.md`.
- **Document new commands.** A new or changed mise task belongs in the
  "Commands" section of both root instruction files in the same change, and in
  the root `README.md` when a newcomer would need it.
- **Keep root instructions synchronized.** Any guidance change in `AGENTS.md`
  must also be made in `CLAUDE.md`, and vice versa.
