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
mise run tasks:check
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
mise run test:weather
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

Swift design docs define behavior. The implementation docs have separate jobs:

- `impl/plan.md` defines milestones.
- `impl/scenarios.md` defines promised behavior.
- `impl/tasks.md` defines work items and assigns each scenario.

Any change under `docs/swift/impl` must pass `mise run tasks:check`. Keep current
status in the platform README instead of copying it into other pages. Document
new commands in both root agent instruction files and, when users need them,
in this guide or the root README.

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
