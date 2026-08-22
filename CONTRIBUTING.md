# Contributing to Cog

Cog is one repository with a shipping Swift package and a future Kotlin
project. The platform designs stay independent. Start with the root README for
the product and with `docs/swift/README.md` for the current Swift status,
decisions, and implementation documents.

## Prerequisites

- Install [mise](https://mise.jdx.dev) and run `mise install` from the root.
- Use a full Xcode, not Command Line Tools alone. The tested release toolchain
  and runner topology are recorded in `docs/maintainers/ci.md`.
- Use Jujutsu for day-to-day version control in this colocated repository.

`mise.toml` is the authoritative command list. Run `mise tasks` rather than
copying command spellings from an old issue or review.

## Common verification

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

Filtered test runs always go through a mise wrapper, for example
`mise run test --filter 'DECL-01|ONE-05'`. Never invoke a filtered
`swift test` directly: SwiftPM exits successfully when the filter selects
nothing, while Cog's wrapper verifies selection and the executed count. Root
package test tasks run serially because the benchmark-sized graph scenarios
otherwise starve time-bounded actor tests on the MainActor.

Apple-boundary and example verification use `mise run test:simulator`,
`mise run build:weather`, `mise run test:weather`,
`mise run build:storefront`, and `mise run test:storefront-ui`. Benchmark and
CogLint artifact commands are documented in `AGENTS.md` and `CLAUDE.md` and are
listed by `mise tasks`.

## Test topology

- Public behavior proofs live in
  `swift/Tests/CogTests/Scenarios/<PREFIX>/...ScenarioTests.swift`, import only
  `Cog` and `CogTesting`, and own scenario IDs.
- Implementation proofs live under
  `swift/Tests/CogTests/Infrastructure/<seam>/...InfrastructureTests.swift`.
  They may use `@testable import Cog` and own no scenario.
- Observation and SwiftUI proofs live in `CogBoundaryTests`; shared graph-shape
  run counts live in `CogScenarioTests`.
- Expected compiler failures live outside every SwiftPM target in
  `swift/CompileFail` and run through `mise run test:compilefail`.
- Performance claims require the guarded benchmark commands and an environment
  recorded beside every durable number.

## The documentation site

`docs/` is published at [skeswa.github.io/cog](https://skeswa.github.io/cog/)
by a VitePress site whose configuration lives in `docs/.vitepress/`. Working on
it needs the repository's only npm dependency tree — the Swift package itself
still resolves with none:

```sh
npm ci
mise run docs:dev       # hot-reloading local site
mise run docs:build     # production build; fails on any dead link
mise run docs           # the whole site, DocC reference included
```

`mise run docs:build` treats a broken cross-document link as a build failure, so
run it after moving or renaming a document. Adding a document means adding it to
the sidebar in `docs/.vitepress/navigation.mts` as well as to the platform
README that lists the reading order.

## Documentation and plans

The Swift design documents are normative for behavior. `impl/plan.md` owns
milestone scope, `impl/scenarios.md` owns promised stories, and `impl/tasks.md`
owns executable slices and scenario ownership. A change under
`docs/swift/impl` must leave `mise run tasks:check` green. New commands must be
documented in both root agent instruction files and, when consumers or new
contributors need them, here or in the root README.

Keep current project status in the platform README. Other documents should link
to that snapshot instead of copying milestone state.

## Revisions

Use `jj st`, `jj diff`, `jj commit`, `jj bookmark`, and `jj git push`. There is
no staging area. Keep one logical change per revision and follow the
[change-management process](./docs/maintainers/changes.md) for Conventional
Commit syntax, breaking notes, version consequences, and the exact local and
GitHub ranges. Maintainers alone may add `Release-As`. Run
`mise run changes:check` before pushing.

Pull requests use rebase merging so those revision descriptions remain the
linear release history. Release Please turns that history into versions,
changelogs, draft release PRs, lightweight bare-semver tags, and draft GitHub
Releases. Candidate builds and publication run only in GitHub Actions; see the
[Swift release runbook](./docs/maintainers/releasing.md).

Every change must leave `mise run fmt:check` green and must run the smallest
relevant behavior, release, simulator, or benchmark gates needed to support its
claims.
