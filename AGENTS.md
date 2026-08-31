# AGENTS.md

This file guides coding agents working in this repository. `CLAUDE.md` mirrors
it for Claude Code; keep the two files in sync.

## What this is

**Cog**, a fine-grained state-management project for native mobile UI:

- a Swift library for SwiftUI on iOS, built over `@Observable` at the boundary
  with one app-wide MainActor-confined dependency graph inside — implemented;
  and
- a Kotlin library for Jetpack Compose on Android with one app-wide graph —
  fully designed, not implemented.

<!-- x-release-please-start-version -->

The current published Swift release is 0.6.1.

<!-- x-release-please-end -->

That line is the only status this file carries, and Release Please moves it.
Everything else — what is implemented, what is in flight, what is open — lives
in `docs/swift/README.md` and `docs/kotlin/README.md`. Read it there and update
it there.

## Where things are

Follow the map down rather than searching. Each entry is authoritative for its
subject, and this file does not restate them.

| To learn                                       | Read                                            |
| ---------------------------------------------- | ----------------------------------------------- |
| What Cog is, its principles, how to install it | `README.md`                                     |
| Setup, checks, test placement, docs, revisions | `CONTRIBUTING.md`                               |
| The cross-platform state model and vocabulary  | `docs/design.md`                                |
| The Swift docs, and where each one starts      | `docs/swift/README.md`                          |
| Packages, why each is separate, the source map | `docs/swift/impl/architecture/codebase-tour.md` |
| How an app should use Cog                      | `docs/swift/handbook/index.md`                  |
| The Swift API and architecture design          | `docs/swift/design/exploration.md`              |
| What is settled and what is open               | `docs/swift/design/exploration.md` §10          |
| How the runtime is actually built              | `docs/swift/impl/architecture/index.md`         |
| Promised behavior, as scenario IDs             | `docs/swift/impl/scenarios.md`                  |
| What the current build measures                | `docs/swift/impl/perf.md`                       |
| The linter, its rules, and its distribution    | `docs/swift/design/lint.md`                     |
| Kotlin                                         | `docs/kotlin/README.md`                         |
| Commits, CI, and releases                      | `docs/maintainers/`                             |

Every package under `swift/` has its own `README.md` explaining why it is a
separate package and how to run it; read that before changing one. `tools/`
holds the Node checkers and test wrappers the mise tasks invoke, and
`.github/workflows/` is explained by `docs/maintainers/ci.md`.

Two names collide, so always path-qualify them: `docs/swift/design/perf.md` is
the performance design, `docs/swift/impl/perf.md` is the performance record.

## Commands

`mise.toml` is authoritative and `mise tasks` prints every task with a
description. `CONTRIBUTING.md` names the ones an ordinary change needs.

Three things that list will not tell you:

- **Never run `swift test` yourself, especially with `--filter`.** SwiftPM
  exits 0 when a filter selects nothing, so a raw filtered run reports a green
  for work it never ran. The `mise run test*` wrappers enumerate tests before
  the run and check the executed count after it. Extra arguments pass through:
  `mise run test --filter 'DECL-01|ONE-05'`.
- **Every change must leave `mise run fmt:check` green.**
- **A new or changed task is documented where it is used**, not here:
  `CONTRIBUTING.md` when a contributor needs it, the root `README.md` when a
  newcomer does, and the runbook under `docs/maintainers/` when only a release
  or CI does.

## Working here

- **Do not re-litigate settled decisions.** The ledger is
  `docs/swift/design/exploration.md` §10, mirrored for Kotlin in
  `docs/kotlin/exploration.md` §10. Designs harden through `/vette` reviews;
  when a decision is accepted, update the ledger and the platform README
  snapshot together.
- **Keep performance claims benchmark-gated.** A representation choice stays
  open until it is measured, and the measurement goes in
  `docs/swift/impl/perf.md` with the environment that produced it.
- **Make Swift source explain its contracts.** Every Swift file and every
  internal-or-higher declaration needs substantive documentation comments
  covering what a signature cannot say: identity and storage, ownership and
  lifetime, isolation, turn and settlement ordering, dependency tracking, and
  cancellation invariants. Document a private helper when correctness rests on
  a non-obvious invariant. Explain why; never restate syntax. A broad comment
  audit uses emitted symbol graphs to find gaps and mechanically confirms the
  resulting diff is comment-only.
- **Keep `CLAUDE.md` and `AGENTS.md` synchronized.** They differ only in their
  title and opening sentence. Any change to one is a change to both, in the
  same revision.

## App conventions

`coglint` enforces most of these; `docs/swift/design/lint.md` maps each rule to
the convention it checks, and `mise run lint:swift` runs them over the library,
examples, Storefront, and tests. The handbook chapter linked beside each rule
is the explanation, with worked examples from the three example apps.

| Rule                                                                              | Chapter                                  |
| --------------------------------------------------------------------------------- | ---------------------------------------- |
| App state lives in `…State+Aspect.swift` families                                 | `docs/swift/handbook/app-structure.md`   |
| Keyless declarations end in `Cog`; boxes end in `Cogs`                            | `docs/swift/handbook/declaring-state.md` |
| Manual sources are `private` and underscored; the projection takes the clean name | `docs/swift/handbook/declaring-state.md` |
| Every read is unwrapped into a domain local, read flatly, never repackaged        | `docs/swift/handbook/reading-state.md`   |
| Every primitive is wrapped in a named `CogOps` op                                 | `docs/swift/handbook/writing-state.md`   |
| Every Cog-using view resolves `\.cogs` itself                                     | `docs/swift/handbook/swiftui.md`         |
| SwiftUI bindings are tracked adapters on `Cogs`, never built in a view            | `docs/swift/handbook/swiftui.md`         |
| Initial app state is written in a mechanism's `operate`, not the entry point      | `docs/swift/handbook/side-effects.md`    |
| Navigation containers have one source and converge on named ops                   | `docs/swift/handbook/navigation.md`      |
| Each test and preview gets one isolated runtime                                   | `docs/swift/handbook/testing.md`         |

Library-internal conventions — traps, deinitializer isolation, and the arena
checklists — are in `docs/swift/impl/architecture/codebase-tour.md` under
"Change checklists".

## Version control

`CONTRIBUTING.md` covers the workflow and `docs/maintainers/changes.md` is the
authoritative message, validation, and release-input process. In short: this is
a Jujutsu repository colocated with git, the working copy is itself a commit,
and day-to-day work uses `jj` rather than `git add`/`git commit`.

Two obligations are easy to miss:

- **One logical change per revision.** If the working copy has grown past one,
  `jj split` it rather than describing a grab bag. Run `mise run changes:check`.
- **Paired obligations land together** in the one revision that makes them
  true: `CLAUDE.md` with `AGENTS.md`, a new command with its documentation, a
  new scenario with its test.
