# Change management

_August 21, 2026._

Every commit on `main` is release input. Release Please reads commit messages
to choose versions and write the changelog. Rebase merges keep those messages
in the final history.

This page defines the process. The [CI runbook](./ci.md) covers Actions
security. The [release runbook](./releasing.md) covers release steps.

## Commit messages

Use one Jujutsu revision for each logical change. Use this format:

```text
type(optional-scope)!: short command
```

The scope and `!` are optional. Allowed types are:

```text
build  chore  ci  docs  feat  fix  perf  refactor  revert  style  test
```

Use a lowercase type and a command such as `fix: preserve the latest value`.
Do not end the first line with a period. Each line must be at most 100
characters.

For a breaking change, add `!` and a footer:

```text
feat(swift)!: rename the mutation primitive

BREAKING CHANGE: Replace commit with turn throughout the public API.
```

Release Please can read extra Conventional Commit messages in the body when
one revision needs more than one changelog entry. Normal work should use one
message per revision. Split unrelated work with jj.

Cog is below 1.0. Features and breaking changes bump the minor version. Fixes
and performance changes bump the patch version.

`Release-As: <version>` forces a version. Only the maintainer may use it. The
GitHub actor must be `skeswa`; a local revision must use author email
`me@sandile.io`.

## Local check

Install packages with `npm ci`, then run:

```sh
mise run changes:check
```

The task tests the checker, then checks each non-empty jj description in
`main..@`. It ignores an empty jj working copy because jj creates one during
normal work. The repo pins Commitlint CLI 21.2.1 and its config 21.2.0.

## GitHub workflow

`.github/workflows/conventional-commits.yml` runs on every pull request and
every push to `main`. It has no path filters. Its check is named
`Conventional Commits`.

The workflow checks:

- PR commits in `base.sha..head.sha`;
- push commits in `before..after`; and
- every ancestor through `after` if a new history has an all-zero `before` SHA.

The GitHub check rejects empty commit messages. The workflow checks out the
exact event head with full history, not GitHub's test merge commit. It installs
the pinned tools and runs `mise run changes:check`.

The job runs on hosted Ubuntu with `contents: read`. Checkout does not keep
credentials, so the job cannot write to the repo. A new run on the same ref
cancels the old run.

## Release pull requests

GitHub does not start normal PR workflows for a release PR made with this
repo's token. The manual candidate run in `swift-ci.yml` has its own hosted
`Conventional Commits` job. It checks the exact release PR range. Recovery mode
checks the tag commit against its parent. A local check cannot replace this
Actions result.

The rules live in `commitlint.config.mjs`, `tools/check-changes.mjs`, and
`tools/lib/changes.mjs`. Their tests live in `tools/test-changes.mjs` and
`tools/fixtures/changes/`. Update them and this page together.
