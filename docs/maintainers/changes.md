# Change management

_August 21, 2026._

Every commit on `main` can affect a release. Release Please reads commit
messages to choose a version and write the changelog. Rebase merges keep those
messages in the final history.

This page defines commit rules. See [CI operations](./ci.md) for workflow
security and [the release runbook](./releasing.md) for release steps.

## Write a commit message

Use one Jujutsu revision for each logical change. Its message must start with:

```text
type(optional-scope)!: short command
```

The scope and `!` are optional. Use one of these lowercase types:

```text
build  chore  ci  docs  feat  fix  perf  refactor  revert  style  test
```

Write the summary as a command, such as `fix: preserve the latest value`. Do
not end it with a period. Keep every line at 100 characters or fewer.

Use `!` and a footer for a breaking change:

```text
feat(swift)!: rename the mutation primitive

BREAKING CHANGE: Replace commit with turn throughout the public API.
```

A commit body may include extra Conventional Commit messages when one revision
must make several changelog entries. Normal changes should use one message.
Split unrelated work into separate jj revisions.

Cog is below 1.0. Features and breaking changes raise the minor version. Fixes
and performance work raise the patch version.

`Release-As: <version>` forces a version. Only the maintainer may use it. The
GitHub actor must be `skeswa`. A local revision must use `me@sandile.io` as its
author email.

## Check local revisions

Install packages with `npm ci`, then run:

```sh
mise run changes:check
```

The task first tests its own checker. It then checks every non-empty jj message
in `main..@`. It ignores an empty working-copy revision because jj creates one
during normal work. The repo pins Commitlint CLI 21.2.1 and Commitlint config
21.2.0.

## GitHub check

`.github/workflows/conventional-commits.yml` runs for every pull request and
every push to `main`. It has no path filters. The required check is named
`Conventional Commits`.

It checks:

- PR commits in `base.sha..head.sha`;
- pushed commits in `before..after`; and
- all commits through `after` when an all-zero `before` SHA marks new history.

GitHub rejects empty commit messages. The job checks out the exact event head
and full history, not GitHub's temporary merge commit. It runs on hosted Ubuntu
with only `contents: read`. Checkout does not save credentials. A newer run on
the same ref cancels the older one.

## Release PR check

GitHub does not start normal PR workflows for a release PR made with this
repo's token. The manual candidate run in `swift-ci.yml` therefore includes a
hosted `Conventional Commits` job for the exact release PR range. In recovery,
it checks the tag commit against its parent. A local result cannot replace this
Actions check.

The rules are in `commitlint.config.mjs`, `tools/check-changes.mjs`, and
`tools/lib/changes.mjs`. Tests are in `tools/test-changes.mjs` and
`tools/fixtures/changes/`. Update the rules, tests, and this page together.
