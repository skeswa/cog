# Releasing Cog for Swift

_August 21, 2026._

Every release step runs in GitHub Actions. A maintainer computer does not build
files, edit the changelog, create tags, upload assets, deploy docs, or publish
plugins. The maintainer reviews the release PR and merges it. Every other step
starts itself.

[Change management](./changes.md) defines commit messages and checked ranges.
The policy below defines what a release is and who may produce one; the
numbered sections after it give the Actions UI steps.

## Release policy

- **Authority.** Release preparation and publication run entirely in GitHub
  Actions. A maintainer workstation may perform optional developer preflight,
  but it never supplies release evidence or bytes. Human control is review and
  the merge of the release PR. The `cog-release` and `coglint-release`
  environments scope write tokens to their publisher jobs and hold no required
  reviewer, because every fact a reviewer would check by eye is verified
  mechanically before any write.
- **History.** jj revision descriptions are Conventional Commits and survive
  rebase-only pull-request merges as the authoritative linear release input.
  The required `Conventional Commits` check has no path filter and lints every
  commit in the GitHub PR or push range. `Release-As` is maintainer-only.
- **Versioning.** Release Please v17.6.0 uses its manifest-driven `simple`
  strategy. `version.txt` is the runtime version source; the private Node
  documentation package remains 0.0.0. Before 1.0, breaking changes and
  features bump the minor, while fixes and performance changes bump the patch.
  The one-time manifest begins at 0.0.0 and bootstraps after
  `16ade4bac358bf1c6f6dbc6e95fad2d467600250`, so the divergent manual 0.4.0 tag
  is neither treated as an ancestor nor replayed.
- **Proposal.** Release Please maintains a draft release PR, `CHANGELOG.md`,
  the manifest, `version.txt`, and only explicitly marked current-version or
  consumer-pin statements. Published changelog entries and historical design
  evidence are immutable inputs. The release PR stays draft until its exact
  current head passes the complete candidate workflow.
- **Candidate.** `swift-ci.yml` requires the release PR number and rejects a
  dispatch at any other SHA. `release.yml` dispatches it whenever Release
  Please proposes or updates the PR; a maintainer may dispatch it again by
  hand. Its hosted revision-range job supplies
  the required `Conventional Commits` context that a repository-token-created
  Release Please PR cannot trigger for itself. The full Actions graph covers
  formatting, host and release tests, both arena configurations, simulator and
  examples, Storefront UI, CogLint integrations, documentation, benchmark
  thresholds, an arm64 native build, and hosted Intel verification of the same
  downloaded bytes. The final version/PR-head-qualified artifact retains its
  archive, checksum, and JSON provenance for publication.
- **Cog publication.** After the draft release PR rebase-merges, Release Please
  force-creates the permanent lightweight bare-semver tag and draft GitHub
  Release. The hosted publisher waits at `cog-release`, then verifies the
  workflow identity, conclusion, PR head, tag/tree equality, version,
  provenance, toolchains, architectures, and checksum before uploading assets,
  titling `Cog <version>`, and publishing. Kotlin remains outside this tag line
  and uses Maven coordinates.
- **Docs.** A narrow hosted job with only `actions: write` dispatches
  `docs.yml` at the tag after publication, because repository-token-created
  events do not generally start another workflow. DocC and VitePress still
  merge into the one Pages deployment at
  `https://skeswa.github.io/cog/documentation/cog/`.
- **Sibling.** After Cog publishes and Docs is dispatched, a narrow job
  starts the `coglint-plugins` repository's workflow with the Cog version,
  under a token scoped to that repository's Actions and nothing else. Read-only
  preparation verifies the public tag, assets, checksum, and provenance; runs
  the exact tag's generator; and smoke-tests SwiftPM. A `coglint-release` job
  with only sibling `contents: write` re-hashes without executing
  downloaded Cog code, requires sibling `main` unchanged, fast-forwards one
  conventional release commit and creates the matching immutable tag in one
  atomic, non-forced push. A retry accepts an existing tag only when its commit
  and regenerated managed tree are identical. Final public consumption is
  read-only.
- **Recovery.** A manual `release.yml` dispatch accepts an existing immutable
  tag and merged release PR, rebuilds the complete candidate at that tag in
  Actions, and retries the same protected publisher. Matching partial assets
  are reused, divergent assets fail, and tags are never moved or replaced.
- **Serialization.** The repository-level release concurrency group, draft
  release PR, immutable tag, and protected publisher admit one Cog publication
  at a time. The sibling concurrency group and unchanged-main proof serialize
  the coupled plugin publication behind it.

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
release tag. The allowlist records the reviewed compatibility delta; it is not a
substitute for a source-migration decision. Rerun the check and require it to
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

`release.yml` dispatches **Swift CI** at the PR's head each time Release Please
proposes or updates the PR, so a candidate is normally already running by the
time you open the PR. To run one again by hand, open **Actions → Swift CI → Run
workflow**, select the Release Please branch, enter its PR number in
`release_pr`, leave `recovery_tag` empty, and start the workflow.

Either way, the workflow looks up the PR again. It fails if the selected ref is not the
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
tag and a draft GitHub Release. `Publish verified release` then runs in the
`cog-release` environment, which gives the hosted publisher `contents: write`
and asks nobody for approval. Before it publishes, the job checks that:

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

Nothing waits for Docs to finish. If the
[published API reference](https://skeswa.github.io/cog/documentation/cog/)
does not open afterwards, dispatch `docs.yml` at the tag by hand.

## 4. Publish `coglint-plugins`

After the Docs dispatch, `release.yml` starts **Publish CogLintPlugins** in
skeswa/coglint-plugins with the published Cog version. It authenticates with
the `COGLINT_PLUGINS_DISPATCH_TOKEN` repository secret, a fine-grained token
for that repository with Actions write and nothing else; the job fails with a
named error when the secret is missing. Every check and write inside the
sibling workflow uses that repo's own token. To start it by hand, open
**skeswa/coglint-plugins → Actions → Publish CogLintPlugins**, select `main`,
and enter the Cog version.

The read-only preparation job:

1. requires the public Cog tag and release;
2. downloads and checks all three Cog assets;
3. checks out the exact Cog tag and runs its generator;
4. checks the generated package and a test SwiftPM app; and
5. records the sibling `main` SHA and uploads the generated tree.

The publish job then runs in `coglint-release`, which scopes `contents: write`
to it and holds no reviewer. It runs no downloaded Cog code. It
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
