# Releasing Cog for Swift

_August 20, 2026._

This is the operational checklist for a Swift release. The normative version
policy and publication ordering remain in
[`docs/swift/impl/plan.md` § Release process](../swift/impl/plan.md#release-process),
and the current release task in `docs/swift/impl/tasks.md` owns the exact gate
for its version. Do not use this runbook to bypass either one.

## Prepare the candidate

1. Start from an empty Jujutsu working copy whose parent is the exact candidate
   commit. Confirm the release task's dependencies and immutable CI links.
2. Update `CHANGELOG.md`, consumer version examples, CogLint artifact metadata,
   and the sibling `CogLintPlugins` package inputs wherever the release task
   requires them. One version must identify the source package, documentation,
   linter, and binary metadata.
3. Run the release task's complete verification set. For the current package,
   its local foundation is:

   ```sh
   mise run fmt:check
   mise run workflows:check
   mise run tasks:check
   mise run api:check 0.4.0
   mise run test:matrix
   mise run test:cores
   mise run test:value-references
   mise run test:release
   mise run test:compilefail
   mise run test:simulator
   mise run build:weather
   mise run test:weather
   mise run test:storefront
   mise run build:storefront
   mise run lint:swift
   mise run test:lint-documentation
   mise run bench:thresholds:check
   ```

   Replace `0.4.0` with the actual preceding release tag. A binary-backed
   release also runs the artifact, build-tool plugin,
   command-plugin, and distribution gates named by `mise tasks`. Candidate CI
   must prove the arm64 artifact built on the pinned mini and the downloaded
   x86_64 member on the hosted Intel runner.

4. Review the public-API diagnostic. An intended 0.x minor break belongs in the
   changelog and candidate review; do not silence an accidental break with an
   allowlist. Patch releases remain additive or corrective.
5. Close the non-mutating candidate gate before creating a tag. Later work may
   continue only from a child revision and cannot change the candidate commit.

## Tag the candidate

All ordinary source pushes use Jujutsu. The annotated release tag is the sole
exception because Jujutsu does not author annotated Git tags:

```sh
jj st
jj git push
cog_release=0.5.0
git tag -a "$cog_release" -m "Cog $cog_release"
git push origin "$cog_release"
```

Resolve the actual version from the release task; the value above is only an
example. Verify the tag names the approved commit before pushing it. Bare
semantic-version tags belong to the Swift package and are permanent: never
move, replace, or force-push a published tag.

## Publish and verify

- A source-only release verifies the tag-triggered DocC deployment and exact
  scratch-package consumption before creating its GitHub Release.
- A binary-backed CogLint release publishes the GitHub Release and checksummed
  artifact first, because the consumer manifest needs that immutable asset URL.
  Then verify Pages, download and recompute the asset checksum, publish the
  version-matched sibling manifest tag, and smoke-test plugin consumption from
  a scratch iOS application.
- Confirm the GitHub Release notes match `CHANGELOG.md`, the documentation
  routes resolve, and a consumer can select both `Cog` and `CogTesting` at the
  exact tag without resolving development-only dependencies.
- Record the terminal verification links in the release task. The next release
  chain begins only after this one closes.

If a defect appears after tagging, fix forward through a new candidate and
patch version. Do not repair history by retagging the old version.
