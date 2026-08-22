# Releasing Cog for Swift

_August 21, 2026._

Cog releases are produced entirely in GitHub Actions. A maintainer workstation
does not build candidate bytes, edit a changelog, create a tag, upload an asset,
deploy documentation, or publish the sibling plugin package. Human control is
limited to reviewing pull requests, dispatching workflows, approving queued
runs, and approving protected environments.

The normative version policy remains in
[`docs/swift/impl/plan.md` § Release process](../swift/impl/plan.md#release-process).
This runbook owns the Actions UI sequence and the evidence a maintainer reviews.
The [change-management process](./changes.md) owns Conventional Commit
authoring and the exact local, pull-request, push, and candidate ranges.

## How a release is proposed

`release.yml` runs Release Please after every push to `main`. It checks out no
repository code and holds only `contents`, `pull-requests`, and `issues` write
permissions. The manifest-driven `simple` strategy reads Conventional Commit
revision descriptions, updates `version.txt` and the marked consumer pins,
generates `CHANGELOG.md`, and maintains one draft release pull request.
Release Please also owns that file's generated layout, so Oxfmt excludes it;
the release-configuration gate instead checks its immutable published sections
and exact bootstrap entries.

Cog is pre-1.0: a breaking change or feature produces a minor release, while a
fix or performance change produces a patch. `Release-As` is a maintainer-only
one-time override. The bootstrap migration uses it to propose 0.5.0 without
replaying the divergent manual 0.4.0 release.

Review the draft release pull request for all of the following:

- the proposed version is the intended bare semantic version;
- `version.txt`, the manifest, and every marked consumer pin agree;
- the changelog contains only changes since the configured bootstrap or prior
  Release Please release;
- breaking notes match the public API changes and no published changelog entry
  was rewritten; and
- the pull request remains a draft until its exact current head has passed the
  candidate workflow.

GitHub does not recursively trigger ordinary checks for a pull request created
by the repository token. Approve any queued run in the Actions UI when GitHub
asks. The exact-head candidate dispatch supplies the required
`Conventional Commits` check context for this bot-created PR; do not replace
either Actions result with workstation evidence.

## Validate the exact release PR head

Open **Actions → Swift CI → Run workflow**. Select the Release Please branch,
enter its pull request number in `release_pr`, and leave `recovery_tag` empty.
The workflow resolves the PR again and fails unless the dispatched SHA is its
current head. If Release Please updates the branch, dispatch a new candidate;
an older successful run no longer authorizes publication.

The `Release candidate` job becomes green only after the complete run succeeds:
the release PR's Conventional Commit range, formatting, all host isolation
legs, the public arena configurations, release tests, simulator and example
tests, Storefront correctness and UI measurement, compile-fail fixtures,
CogLint dogfood and plugin integrations, documentation, the task ledger,
benchmark thresholds, the arm64 artifact build, and the hosted Intel proof over
those exact downloaded bytes.

The final Actions artifact is named with both version and PR-head SHA and is
retained for 90 days. It contains the archive, checksum, and JSON provenance.
The provenance binds the PR, source SHA and tree, workflow run, Xcode and Swift
toolchains, both architectures, and both host-selection proofs.

After the whole run succeeds, mark the release PR ready and rebase-merge it.
Cog permits rebase merging only, so every validated jj revision description
survives on the linear `main` history Release Please reads.

## Publish Cog

The merge starts `release.yml` again. Release Please creates the permanent
lightweight bare-semver tag immediately and opens a draft GitHub Release. The
`Publish verified release` job then waits at the protected `cog-release`
environment.

Before approval, confirm the job names the expected tag, release PR, candidate
run, and version. Approval lets the hosted publisher receive `contents: write`.
It independently verifies all of these facts before mutating the release:

- the tag is lightweight, points at the Release Please commit, and agrees with
  `version.txt`;
- the rebased tag tree equals the validated release-PR head tree;
- the candidate is a successful `workflow_dispatch` run of `swift-ci.yml` for
  that source;
- the artifact name, workflow run, PR, version, source tree, toolchains,
  architectures, probes, and SHA-256 checksum agree with JSON provenance; and
- any already-uploaded asset is byte-identical, so a retry cannot replace a
  divergent archive.

The publisher uploads the archive, checksum, and provenance, titles the release
`Cog <version>`, and removes its draft flag. A separate job with only
`actions: write` then dispatches `docs.yml` at the tag. This explicit dispatch
is required because events created by the repository token do not generally
start another workflow.

Wait for Docs to deploy the tag-built DocC archive and the VitePress site. The
published API reference must resolve at
`https://skeswa.github.io/cog/documentation/cog/` before publishing the sibling.

## Publish `coglint-plugins`

Open **skeswa/coglint-plugins → Actions → Publish CogLintPlugins**, dispatch
`main`, and enter the published Cog version. That repository uses only its own
repository-scoped token.

The read-only preparation job requires the public Cog tag and published
release, downloads all three assets, verifies their checksum and provenance,
checks out the exact Cog tag, runs that tag's generator, validates the generated
manifest, and builds a scratch SwiftPM consumer. It records the current sibling
`main` SHA and uploads the generated tree as a workflow artifact.

The publish job waits at `coglint-release`. Approve it only after preparation is
green. Under its sole `contents: write` grant, the job executes no downloaded
Cog code. It re-hashes the generated artifact, requires sibling `main` to remain
unchanged, rejects an existing divergent version or tag, fast-forwards one
`chore(release): publish CogLintPlugins <version>` commit and the matching bare
lightweight tag in one atomic, non-forced push. An already-published retry is
accepted only when the tag, commit, and regenerated managed tree are identical.
A final read-only hosted macOS job resolves that public tag from a scratch
package and executes its build-tool plugin.

The release is complete only when the Cog release is published, Docs is green,
and the sibling's final exact-version consumer is green.

## Recover a failed publication

Never move or replace a release tag. For an existing tag whose publication did
not finish, open **Actions → Release → Run workflow** and enter the tag and its
merged Release Please PR number. The recovery job proves the tag is lightweight
and version-matched, dispatches the complete Swift CI workflow at that tag, and
waits for a new successful candidate. The protected publisher then repeats the
same provenance and byte checks. Matching assets are reused; divergent assets
stop the run.

If the released source itself is defective, fix forward through a new
Conventional Commit and a new patch or minor release. Recovery repairs the
pipeline around an immutable source release; it never repairs history.
