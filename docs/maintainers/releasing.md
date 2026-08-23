# Releasing Cog for Swift

_August 21, 2026._

Every release step runs in GitHub Actions. A maintainer computer does not build
files, edit the changelog, create tags, upload assets, deploy docs, or publish
plugins. The maintainer reviews pull requests, starts workflows, approves runs,
and approves protected environments.

The [Swift release policy](../swift/impl/plan.md#release-process) defines version
rules. [Change management](./changes.md) defines commit messages and checked
ranges. This page gives the Actions UI steps.

## 1. Review the release PR

After each push to `main`, `release.yml` runs Release Please. It reads
Conventional Commit messages and keeps one draft release PR up to date. That PR
updates:

- `version.txt`, the release manifest, and marked version pins;
- `CHANGELOG.md`; and
- the next bare semantic version, such as `0.5.0`.

Release Please uses a minor release for a feature or breaking change before
1.0. It uses a patch for a fix or performance change. Only the maintainer may
use `Release-As` to force a version.

`package.json` stays at `0.0.0` because it is only for private docs tools. It is
not a Cog version source. Release Please owns the changelog layout, so do not
format or edit generated sections by hand.

For an intentional public API break, run `mise run api:check` against the newest
release tag and review every Swift API digester diagnostic. Copy only the
accepted diagnostics, verbatim, into
`tools/api-breakage-allowlists/<baseline>.txt`; the filename must match that
release tag. Migration typealiases do not necessarily suppress signature-change
diagnostics, so the allowlist records the reviewed compatibility delta rather
than the availability of a source migration. Rerun the check and require it to
pass before the release PR. Never add a broad or unreviewed suppression.

Check that:

- the version has no `v` or component prefix;
- `version.txt`, the manifest, and marked pins agree;
- the changelog includes only changes since the last configured release;
- breaking notes match the public API changes;
- old changelog entries did not change; and
- the PR stays a draft until its exact head passes the candidate workflow.

Release Please checks out no repo code and receives only `contents`,
`pull-requests`, and `issues` write access. GitHub may ask for approval before a
bot-created PR check runs. Approve it in Actions. A local result cannot replace
an Actions result.

## 2. Test the exact PR head

Open **Actions → Swift CI → Run workflow**:

1. Select the Release Please branch.
2. Enter its PR number in `release_pr`.
3. Leave `recovery_tag` empty.
4. Start the workflow.

The workflow looks up the PR again. It fails if the selected ref is not the
PR's current head. If Release Please changes the branch, start a new candidate.
An older run no longer counts.

`Release candidate` turns green only after all commit, format, host, arena,
release, simulator, example, Storefront, compile-fail, CogLint, docs, task, and
benchmark checks pass. The mini builds the arm64 and x86_64 CogLint files. A
hosted Intel Mac then tests the downloaded x86_64 file without rebuilding it.

The final artifact name includes the version and PR-head SHA. It is kept for 90
days and contains the archive, checksum, and JSON record. That record names the
PR, source commit and tree, workflow run, Xcode and Swift versions, both CPU
types, and both file-selection checks.

When the whole run passes, mark the PR ready and rebase-merge it. Rebase is the
only allowed merge type, so the tested revision messages stay in `main`.

## 3. Publish Cog

The merge runs `release.yml`. Release Please creates the permanent lightweight
tag and a draft GitHub Release. `Publish verified release` then waits for
approval in the `cog-release` environment.

Before approval, check the shown tag, release PR, candidate run, and version.
Approval gives the hosted publisher `contents: write`. Before it publishes, the
job checks that:

- the tag is lightweight, points at the Release Please commit, and matches
  `version.txt`;
- the tag tree equals the tested PR-head tree, even after rebase;
- the candidate is a successful manual run of `swift-ci.yml` for that source;
- the artifact name, run, PR, version, tree, tools, CPU types, checks, and
  SHA-256 checksum match the JSON record; and
- any asset already present has the same bytes.

The job uploads the archive, checksum, and record, names the release
`Cog <version>`, and publishes it. A separate job with only `actions: write`
starts `docs.yml` at the tag. This direct start is required because events made
by the repository token do not usually start another workflow.

Wait for Docs to finish. Confirm that the
[published API reference](https://skeswa.github.io/cog/documentation/cog/)
opens before publishing plugins.

## 4. Publish `coglint-plugins`

Open **skeswa/coglint-plugins → Actions → Publish CogLintPlugins**. Select
`main`, enter the published Cog version, and start the workflow. It uses only
that repo's own token.

The read-only preparation job:

1. requires the public Cog tag and release;
2. downloads and checks all three Cog assets;
3. checks out the exact Cog tag and runs its generator;
4. checks the generated package and a test SwiftPM app; and
5. records the sibling `main` SHA and uploads the generated tree.

The publish job then waits at `coglint-release`. Approve it only after
preparation passes. Its `contents: write` step runs no downloaded Cog code. It
checks the generated files again, requires `main` to be unchanged, and rejects
a different existing version or tag. It pushes one
`chore(release): publish CogLintPlugins <version>` commit and its matching bare
tag together, without force.

A retry is safe only when the existing tag, commit, and generated files all
match. A final read-only hosted Mac resolves the public tag in a new Swift
package and runs its build-tool plugin.

The release is done when the Cog release is public, Docs is green, and the
sibling's exact-version test is green.

## Recover a failed publication

Never move or replace a release tag. To finish an existing tag, open
**Actions → Release → Run workflow**. Enter the tag and its merged Release
Please PR number.

Recovery proves that the tag is lightweight and matches the version. It starts
the full Swift CI workflow at that tag and waits for a new passing candidate.
The protected publisher then repeats every source, record, and checksum check.
It reuses matching assets and stops on different bytes.

If the released code is wrong, make a fix through a new Conventional Commit and
publish a new patch or minor. Recovery can repair the release process, but it
cannot change released source or history.
