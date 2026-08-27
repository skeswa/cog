# Contributing to Cog

Cog has a working Swift package and a planned Kotlin library. Each platform has
its own design. Read the root README first, then use
`docs/swift/README.md` for current Swift decisions and work.

## Set up

- Install [mise](https://mise.jdx.dev), then run `mise install` at the repo root.
- Use full Xcode. Command Line Tools can build code, but they cannot run this
  repo's Swift tests. The tested Xcode version is in
  `docs/maintainers/ci.md`.
- Use Jujutsu (`jj`) for version control.

`mise.toml` is the command source. Run `mise tasks` for the current list.

The root package targets `.iOS(.v17)` and `.macOS(.v14)` and builds in Swift 6
language mode with `.defaultIsolation(MainActor.self)` — the SE-0466 manifest
API is why the tools version is 6.2 — plus `NonisolatedNonsendingByDefault`,
`ExistentialAny`, `MemberImportVisibility`, and `InternalImportsByDefault`.
Public declarations still state their isolation explicitly. Most tests run on
macOS; UIKit and example checks need a simulator. The same tests run under
{MainActor, nonisolated} × {NNBD on, off}: `COG_TEST_ISOLATION` and
`COG_TEST_NNBD` select a leg and test defines prove which leg ran. The four leg
names — `mainactor-nnbd-on`, `mainactor-nnbd-off`, `nonisolated-nnbd-on`,
`nonisolated-nnbd-off` — are also wrapper modes, which CI uses to run one leg
per job. swift-docc-plugin is gated behind
`COG_DOCC=1`, set only by the docs workflow, so an ordinary consumer resolves a
package with no dependencies at all.

## Run checks

Common checks are:

```sh
mise run fmt:check
mise run test
mise run test:matrix
mise run test:arena-configurations
mise run test:release
mise run api:check
mise run test:compilefail
mise run lint:swift
mise run workflows:check
mise run changes:check
```

Use a mise wrapper for filtered tests:

```sh
mise run test --filter 'DECL-01|ONE-05'
```

Do not run filtered `swift test` commands directly. SwiftPM exits with success
when a filter finds no tests. Cog's wrapper proves that tests were found and
run. Root test tasks also run in order so large graph tests do not block tests
with actor time limits.

Apple and example checks use:

```sh
mise run test:simulator
mise run build:weather
mise run build:todomvc
mise run build:storefront
mise run test:storefront-ui
```

Run `mise tasks` for benchmark and CogLint artifact commands.

## Put tests in the right place

- Public behavior tests go in
  `swift/Tests/CogTests/Scenarios/<PREFIX>/...ScenarioTests.swift`. They import
  only `Cog` and `CogTesting` and own scenario IDs.
- Internal tests go in
  `swift/Tests/CogTests/Infrastructure/<seam>/...InfrastructureTests.swift`.
  They may use `@testable import Cog` and do not own scenario IDs.
- Observation and SwiftUI tests go in `CogBoundaryTests`.
- Shared graph run-count tests go in `CogScenarioTests`.
- Expected compiler errors go in `swift/CompileFail` and run with
  `mise run test:compilefail`.
- Any lasting performance claim must include a guarded benchmark result and
  its test environment.

## Work on docs

The `docs/` site uses the repo's only npm dependency tree. Cog itself still has
no dependencies.

```sh
npm ci
mise run docs:dev       # local site with live reload
mise run docs:build     # production site; fails on broken links
mise run docs           # full site, including DocC
```

When you add a page, add it to `docs/.vitepress/navigation.mts` and to the
platform README that gives its reading order. Run `mise run docs:build` after
moving or renaming a page.

Three conventions govern the pages themselves:

- Dated files are frozen; undated files are living. A living design doc uses a
  short lowercase name and carries an authorship date below its title.
- Swift and Kotlin documents own their own platform APIs, runtime mechanics,
  and framework integration. Cross-platform invariants and vocabulary live in
  `docs/design.md`, and a platform choice is never copied across without a
  decision recorded for the receiving platform.
- The companion docs were split out of `exploration.md` and keep its numbering:
  Swift `mechanisms.md` is §6 and `rx.md` is §5.4, and Kotlin `effects.md` and
  `flows.md` mirror them. A reference such as "§6.4" resolves inside the
  companion. Do not renumber these sections.

`.oxfmtrc.json` excludes every `swift/Sources/**/*.docc/**` catalog file,
because Oxfmt rewrites DocC's double-backtick symbol links into code spans and
silently turns each documentation link into plain text. It also excludes
`CHANGELOG.md`, whose layout belongs to the pinned Release Please changelog
writer.

Swift design docs define behavior. The implementation docs have separate jobs:
`impl/scenarios.md` defines promised behavior as test stories, the
`impl/architecture/` chapters explain the implemented runtime, and
`impl/perf.md` records what it measures.

Each kind of change has one home:

- Settled decisions go to `docs/swift/design/exploration.md` §10 and the
  "Where things stand" snapshot in `docs/swift/README.md`.
- Benchmark results go to `docs/swift/impl/perf.md`, with the environment that
  produced them. Retired numbers go to `impl/perf-history.md`. A
  representation choice stays open until it is measured.
- Build, test, and bench commands are defined in `mise.toml`, which is their
  only inventory. Explain a new one where it is used: here when a contributor
  needs it, the root README when a newcomer does, and a `docs/maintainers/`
  runbook when only a release or CI does.
- New documents get mapped in `docs/swift/README.md` or the root `README.md`.
- New or retired scenarios go to `impl/scenarios.md`, which stays the single
  census of promised behavior.

Keep current status in the platform README instead of copying it into other
pages.

## Write revisions

Use `jj st`, `jj diff`, `jj commit`, `jj bookmark`, and `jj git push`. There is
no staging area. Put one logical change in each revision.

Follow [change management](./docs/maintainers/changes.md) for Conventional
Commit messages, breaking notes, version effects, and checked ranges. Only the
maintainer may use `Release-As`. Run `mise run changes:check` before pushing.

Pull requests use rebase merges so each revision message stays in the final
history. Release Please uses that history to make versions, changelogs, release
PRs, tags, and draft GitHub Releases. Candidate builds and publication happen
only in GitHub Actions. See the [release runbook](./docs/maintainers/releasing.md).

Every change must pass `mise run fmt:check` plus the smallest tests or
benchmarks needed to prove it works.
