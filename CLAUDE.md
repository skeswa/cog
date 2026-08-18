# CLAUDE.md

This file guides Claude Code when working in this repository. `AGENTS.md`
mirrors it for other coding agents; keep the two files in sync.

## What this is

The design workspace for **Cog**, a fine-grained state-management project for
native mobile UI. Cog is planned as:

- a Swift library for SwiftUI on iOS, built over `@Observable` at the boundary
  with one app-wide MainActor-confined dependency graph inside; and
- a Kotlin library for Jetpack Compose on Android with one app-wide graph.

The Swift and Kotlin designs exist. Swift work has started: the repository is
now a SwiftPM package rooted at the git root, with the M0 scaffolding
milestone built except its closing gate. The scaffolding is real — package,
formatter, test wrappers, compile-fail harness, document checkers, and CI —
but the library itself is a stub. No Cog API exists yet, and Kotlin has no
implementation at all. The next phase for each platform is the spike in its
`exploration.md` §11, as amended by its `perf.md` §9. For Swift,
`docs/swift/impl/plan.md` turns that spike into milestones with package
layout, tooling, CI, and release steps; `docs/swift/impl/scenarios.md` breaks
those milestones into the test scenarios that drive red-green implementation;
and `docs/swift/impl/tasks.md` decomposes the milestones into dependency-aware
execution tasks scoped to half a day or less, with explicit verification and
every scenario covered by exactly one task.

## Layout

- `README.md` — project overview, shared principles, platform status, the CI
  topology record, and documentation entry points.
- `Package.swift` — the SwiftPM manifest. The package root is the git root;
  every Swift target reaches under `swift/` through an explicit `path:`. The
  manifest reads the isolation, value-reference, core, and edge selectors
  described under "Commands" below.
- `swift/Sources/` — `Cog` (the library, a stub today), `CogTesting` (the
  isolated-context factory for tests and previews), and `CogScenarios` (the
  shared scenario graphs, exported as the non-API `_CogScenarios` product).
- `swift/Tests/` — `CogTests` (correctness), `CogScenarioTests` (run counts),
  and `CogBoundaryTests` (the Observation and SwiftUI boundary). Inside
  `CogTests`, public behavior proofs live under `Scenarios/<PREFIX>/` in
  `...ScenarioTests.swift` files named for their raw IDs; internal proofs live
  separately under `Infrastructure/<seam>/` in
  `...InfrastructureTests.swift` files and green no scenario.
- `swift/CompileFail/` — expected-failure fixtures, deliberately outside every
  SwiftPM target, type-checked in one batched pass.
- `swift/Benchmarks/` — a **separate** SwiftPM package, depending on the root
  by path so the benchmark harness and its allocator backend can never enter
  the dependency graph a consumer resolves. Run it with
  `swift package benchmark` from that directory. Its `README.md` records the
  pinned tool matrix and the MainActor isolation shim; `probes/` holds the
  measurements those pins rest on. Unlike the root package, its
  `Package.resolved` is committed.
- `tools/` — pinned Node tooling: `swift-test.mjs`,
  `swift-simulator-test.mjs`, `weather-test.mjs`, `check-compile-fail.mjs`,
  `check-task-ledger.mjs`, and `check-workflows.mjs`, plus the checkers' own
  fixture suites (`test-task-ledger.mjs`, `test-workflows.mjs`) and
  `fixtures/`.
- `.github/workflows/` — `swift-ci.yml` (format, the four-leg host test
  matrix, simulator tests, the Weather build and tests, release tests,
  compile-fail
  fixtures, and the ledger check, in a self-hosted lane and a GitHub-hosted
  fork lane), `swift-docs.yml` (the DocC archive on the mini, published to
  GitHub Pages from a hosted job on tag push), and `markdown.yml` (Oxfmt and
  the workflow-contract check on GitHub-hosted ubuntu).
- `mise.toml`, `.oxfmtrc.json`, `.swift-format`, `.gitignore`, `LICENSE` —
  task definitions, formatter configuration, and the license.
- `docs/dump-2026-08-06.md` — frozen snapshot of the old Dart and Flutter
  design. Historical background only; never normative and never edited.
- `docs/swift/` — living Swift documents. Start with `README.md`, the map.
  Design docs live in `docs/swift/design/`: `exploration.md` covers the core
  architecture and API; `mechanisms.md` covers mechanisms — the bootstrap-registered
  home for every side effect — and background work;
  `rx.md` maps Rx concepts; `perf.md` covers the data-oriented implementation
  and benchmark plan. Implementation docs live in `docs/swift/impl/`:
  `plan.md` is the implementation plan with milestones, tooling, CI, and
  the release process; `scenarios.md` is the test-scenario tree; `tasks.md`
  is the dependency-aware half-day task graph with explicit verification,
  covering every scenario exactly once.
- `docs/kotlin/` — living Kotlin and Jetpack Compose design documents. Start
  with `README.md`. `exploration.md` covers the core architecture and API;
  `example.md` gives a full worked feature; `effects.md` covers effects and
  background work; `flows.md` maps Flow and reactive concepts; `perf.md`
  covers the runtime candidates and benchmark plan.

## Commands

Every command is a mise task defined in `mise.toml`, which is authoritative;
`mise tasks` prints the current list. mise cannot pin Xcode, so the required
Xcode version lives in the root `README.md` under "Continuous integration".
A full Xcode is required, not the Command Line Tools alone: CLT can build and
lint but `swift test` fails there with `no such module 'Testing'`.

Formatting is split per language under two umbrellas, and either leg can be
run alone:

- `mise run fmt` — `fmt:md` (Oxfmt over Markdown, JSON, YAML, and JavaScript)
  and `fmt:swift` (`swift format --in-place`).
- `mise run fmt:check` — `fmt:check:md` and `fmt:check:swift`
  (`swift format lint --strict`). Writes nothing.

`.oxfmtrc.json` excludes two things from formatting: the frozen
`docs/dump-2026-08-06.md`, and every `swift/Sources/**/*.docc/**` catalog file.
DocC markdown is not ordinary markdown: Oxfmt rewrites its double-backtick
symbol links into single-backtick code spans, which silently turns every
documentation link into plain text.

Tests go through `tools/swift-test.mjs`, never `swift test` directly:

- `mise run test` — the default isolation leg.
- `mise run test:matrix` — all four isolation legs.
- `mise run test:cores` — the complete behavior suite, serialized to keep its
  benchmark-sized graph scenarios from starving time-bounded actor tests,
  under both the explicit `simple` and `arena` core selections without
  changing the shipping default.
- `mise run test:value-references` — the full behavior suite under the
  `inline`, `interned`, and `generic` value-reference layouts.
- `mise run test:release` — the default leg in release configuration.
- `mise run test:simulator` — only `CogBoundaryTests` on the latest iOS
  simulator. Set `COG_SIMULATOR_DESTINATION` to override the destination.
- `mise run test:compilefail` — type-checks every fixture in
  `swift/CompileFail/` in one batched `swiftc -typecheck` pass, failing both
  when a fixture misses its expected diagnostic and when it stops failing.

- `mise run bench` — run the Cog benchmarks from `swift/Benchmarks` in release.
  Extra arguments pass through, as in `mise run bench --filter perf-01-steady-turn`.
- `mise run bench:baseline:update [name]` — record a benchmark baseline in
  `swift/Benchmarks` together with the environment that produced it (Xcode,
  Swift, harness and interposer versions, architecture, host, allocator
  backend). Defaults to `local`.
- `mise run bench:baseline:check [name]` — refuse to compare across
  environments, assert the allocation witness still reports a non-zero malloc
  count, then check the run against that baseline. Baselines live in the
  git-ignored `swift/Benchmarks/.benchmarkBaselines/`; numbers meant to
  outlive a session go in `docs/swift/design/perf.md` §9.6.
- `mise run bench:thresholds:check` — assert the allocation witness is live,
  require every gated benchmark and its committed static threshold, then
  enforce PERF-06's exact p90 zero-allocation result and PERF-10's one-sided
  wall-clock ceilings. This is the benchmark gate CI runs on the pinned mini.
- `mise run bench:thresholds:sentinel` — run a real PERF-10 workload against a
  temporary impossible threshold and pass only when the gate rejects it as a
  regression.

The example app uses the same pinned Xcode as the library:

- `mise run build:weather` — build the Weather app for a generic iOS
  Simulator destination without launching one.
- `mise run test:weather` — run `WeatherTests` on an iOS simulator. Set
  `COG_WEATHER_DESTINATION` to override the destination. This is a separate
  command because `build:weather` uses xcodebuild's `build` action, which
  never compiles a target the Weather scheme lists only under its test
  action.

Extra arguments pass straight through, as in
`mise run test --filter 'DECL-01|ONE-05' --parallel`. **Never run a filtered
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
The isolation matrix is joined by one more build-time selector,
`COG_TEST_VALUE_REFERENCE_LAYOUT`, which chooses how a keyed value reference
physically carries its key (perf §4). It is a **library** setting rather than a
test setting, because the layout is part of the library's representation. Unset
means the selected v1 layout, inline `AnyHashable`, so an ordinary consumer
never opts into a losing candidate; an unrecognized value is a hard manifest
error for the same reason a mistyped isolation leg is. The interned-token and
generic-keyed candidates remain available only for behavior and benchmark
comparison. Generic uses box-produced keyed reference types and conditional
runtime overloads because its concrete `Key` necessarily crosses the public
read surface; it cannot hide entirely behind `CogKey`.
M6 adds two internal library selectors without changing public API.
`COG_TEST_CORE` chooses `simple` (unset/default) or `arena`.
`COG_TEST_EDGE` belongs only to `arena`; unset currently means its first
runnable candidate, `pool`. Supplying an edge beside `simple`, or any
unimplemented spelling, is a hard manifest error so a candidate command cannot
pass without compiling that candidate. The manifest mirrors both choices into
test-target defines for selector sentinels, while ordinary consumer builds
remain on the simple core.

Documentation is a task of its own, because swift-docc-plugin is env-gated
behind `COG_DOCC=1` so ordinary consumers resolve this package with no
dependencies:

- `mise run docs` — builds the DocC archive into `.build/docs/Cog.doccarchive`,
  transformed for static hosting under `--hosting-base-path cog`. It deletes
  the `Package.resolved` the gated resolve writes; that file carries the
  plugin's pins and must never be committed, and `swift-docs.yml` fails the
  build if one survives.

Document and workflow checks, each of which runs its own fixture suite first
because a broken checker cannot validate anything:

- `mise run tasks:check` — validates `docs/swift/impl/tasks.md` against
  `scenarios.md` and `plan.md`.
- `mise run workflows:check` — validates the GitHub Actions hardening
  contract over `.github/workflows`. The contract allows exactly one write
  grant: the `deploy` job of `swift-docs.yml` may hold `pages: write` and
  `id-token: write`, because Pages deployment cannot be done with a read-only
  token. The exception is a named entry in `PERMISSION_EXCEPTIONS`
  (`tools/lib/workflows/checks.mjs`), applies only to that job on a
  GitHub-hosted runner, and is covered by fixtures on both sides.

Every change must leave `mise run fmt:check` green, and any change under
`docs/swift/impl/` must also leave `mise run tasks:check` green.

## Version control

- This is a Jujutsu (`jj`) repository colocated with git. Do day-to-day
  version control with `jj` — `jj st`, `jj diff`, `jj commit`,
  `jj bookmark`, `jj git push` — not `git add`/`git commit`. There is no
  staging area; the working copy is itself a commit. `main` is a jj
  bookmark tracking the GitHub default branch.
- Make all changes as small, well-described revisions: one logical change
  per revision, never a batch of unrelated edits. Describe each revision
  when it lands (`jj commit -m`, or `jj describe` on the working copy) with
  a scoped, imperative summary in the existing style — for example
  `docs(swift): align plan with task graph`. If the working copy has grown
  past one logical change, split it (`jj split`) rather than describing a
  grab bag. Paired obligations — `CLAUDE.md` with `AGENTS.md`, plan with
  task ledger, ledger with issue mirror — belong together in the one
  revision that makes them true.
- Git remains because the outside world consumes it: SwiftPM resolves the
  package from the git repo GitHub serves, CI checks out git, and releases
  are annotated git tags. Create release tags with `git tag -a` in the
  colocated repo (jj does not author annotated tags) and push them with
  `git push origin <tag>`; everything else pushes through `jj git push`.

## Project principles

Every design and implementation choice should preserve four rules:

1. Cog should feel simple to use, read, and reason about.
2. Every state read should be correct.
3. Cog should minimize runtime overhead without weakening the other rules.
4. Cog state should be singular: one running app has one authoritative graph,
   each mutable fact represented in Cog has one writable source in it, and
   screens or features do not create state islands or mirror sources.

For Swift, a correct normal read uses the latest completed turn and settles
every dependency needed for that value. A `Writer` read during a commit sees
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
  derived, async, and read-only projection declarations. Name every box
  `thingCogs`, with plural `Cogs` as the final word. Put narrower qualifiers
  before the suffix (`weatherServiceSourceCog`, `weatherReportSourceCogs`).
  The app runtime remains the ordinary local `cogs`, and ordinary values read
  from the graph receive normal domain names without either suffix.
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
  bootstrap call rather than through any later installation.
- **Wrap every primitive in a named op.** `commit` and `refresh` are how the
  graph is asked to do something, not what an app calls the asking. Application
  code — a view action, a button, a mechanism — calls a domain verb from a
  `CogOps` extension (`cogs.refreshForecast(for: zip)`), never the primitive
  inline. This keeps the declaration a call site resolves to in the state layer
  with the rest of it, and it applies to `refresh` for the same reason it
  applies to `commit`: both are demands on the graph, and neither is domain
  vocabulary.
- **Read flatly; never repackage reads into a projection type.** A view that
  needs several values reads each one on its own line and binds it to a domain
  local, however many there are. Do not gather them into a struct — not one
  built by an initializer taking `Cogs`, and not one built by a `Cogs`
  extension. A projection type adds a layer that must be read to know what the
  view depends on, invites being stored or passed onward, and buys nothing:
  reads in one `body` already come from one settled turn, and each already
  registers on its own so unrelated turns invalidate nothing. If a value is
  genuinely derived rather than merely read together, declare a derived cog and
  read that flatly too.
- **Put initial app state in a mechanism's `operate`, not in the app entry
  point.** `operate` runs inside bootstrap, so its writes settle before
  `bootstrapApp` returns and no watcher observes the pre-initial value on the
  way past. The app entry point bootstraps and retains the runtime; it does not
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
  scenario ID prove it through the public API and `CogTesting` only.
  COUNT-09 through COUNT-11 require the whole behavior suite to pass
  unchanged across the value-reference layout and core swaps, so a scenario test able to
  observe state storage would fail a swap it should not care about. Reach for
  `@testable` only in infrastructure tests, which green no scenario.
- **Give every generic class an explicit `nonisolated deinit`.** With
  `.defaultIsolation(MainActor.self)`, a synthesized `deinit` on a generic
  class is main-actor-isolated, and Swift 6.3.0 and 6.3.3 both crash the
  optimizer on it in release configuration. Debug builds are fine, so
  `mise run test:matrix` will not catch it — only `mise run test:release`
  will. This applies to states, boxes, descriptors, and async state alike.
- **A `deinit` that must touch the graph is spelled `isolated deinit`, and
  its class must not be generic.** A written `deinit` is nonisolated unless it
  says otherwise, so it cannot call a MainActor-isolated method at all — the
  compiler rejects it outright, which is the opposite failure from the
  synthesized case above and is caught at build time rather than in release.
  `ReactionToken` is the worked example: non-generic, so it can take the
  isolation, and the isolation is what lets a handle released on the MainActor
  clean up synchronously instead of hopping. Do not "fix" one of these two
  spellings into the other; they solve opposite problems.
- **Keep platform designs separate.** Shared principles apply to both
  libraries, but Swift decisions are normative only for Swift. Do not assume
  an API or implementation choice also applies to Android without recording an
  Android decision.
- **Preserve shared Swift section numbering.** The companion docs were split
  from `exploration.md`: `mechanisms.md` is §6 and `rx.md` is §5.4. A reference
  such as “§6.4” resolves in `mechanisms.md`. Do not renumber these sections.
- **Preserve shared Kotlin section numbering.** The Kotlin companion docs use
  the same map: `effects.md` is §6 and `flows.md` is §5.4.
- **Dated files are frozen; undated files are living.** Living design docs use
  short lowercase names and carry an authorship date below the title.
- **Map new docs.** Add new Swift docs to `docs/swift/README.md`. Add new
  platform doc sets to the root `README.md`.
- **Do not re-litigate settled decisions.** The Swift snapshot is in
  `docs/swift/README.md` under “Where things stand.” The full settled/open
  ledger is `docs/swift/design/exploration.md` §10. The Kotlin snapshot and
  ledger are
  in `docs/kotlin/README.md` and `docs/kotlin/exploration.md` §10. Designs are
  hardened through `/vette` reviews. When the user accepts a decision from a
  review, update both records for that platform. Track real open questions in
  §10.
- **Keep performance claims benchmark-gated.** Both `perf.md` documents defer
  representation choices to benchmarks. Do not mark them settled without
  measurements.
- **Document new commands.** A new or changed mise task belongs in the
  "Commands" section of both root instruction files in the same change, and in
  the root `README.md` when a newcomer would need it.
- **Keep root instructions synchronized.** Any guidance change in `AGENTS.md`
  must also be made in `CLAUDE.md`, and vice versa.
