# Cog CI and runner operations

_August 21, 2026._

This maintainer runbook records the CI topology, self-hosted runner security
boundary, and repository settings that support Cog's public workflows. The
consumer-facing project overview stays in the root README; workflow behavior is
enforced mechanically by `mise run workflows:check`.

## macOS runner topology

_Settled 2026-08-10 (`M0-05a`)._

macOS CI runs on a personal Apple Silicon Mac mini. Linux jobs stay on
GitHub-hosted `ubuntu`. The mini runs **persistent bare metal with scrub
hygiene**, which the implementation plan sanctions as the alternative to
ephemeral Tart VMs. Tart VMs are recorded as a deferred upgrade, not the
current topology.

Why bare metal won. Tart itself is healthy — it moved to
`github.com/openai/tart`, released 2.35.0 on 2026-08-04, and relicensed to
FSL-1.1-ALv2 in June 2026, dropping the old core-count threshold. The
_orchestrators_ are not: **no macOS ephemeral-runner orchestrator has shipped
a release in 2026.** Cilicon's GitHub Actions provider is organization-only,
so it cannot register a runner for a personal-account repository at all.
Tartelet fits on paper and is the closest candidate, but its last release was
2025-06-13, it has one commit in all of 2026, and four unmerged 2026 pull
requests that read as Tart-compatibility fixes. ekiden is a reference
architecture of Packer templates and shell scripts rather than a product.
Against that, ephemeral VMs would cost roughly 210–350 GB of SSD, cap the
host at two concurrent jobs, and buy little here — fork pull requests
structurally never reach the mini, so the isolation boundary they add is
between _our own_ commits.

The topology:

- **Runner user.** _Amended 2026-08-10 to match the provisioned host._ The
  runner runs as `remembot` on `homemac`, a personal Apple Silicon Mac —
  **an account in the `admin` group**, not the dedicated credential-free
  `cogci` user this section originally specified. That is a genuinely weaker
  posture, and it is recorded rather than quietly assumed: a malicious build
  reaching this runner would execute as a user that can escalate and that
  holds the owner's personal credentials — concretely, one SSH private key,
  two stored `gh` OAuth tokens, the login keychain, and write access to
  `/opt/homebrew`.

  **This was weighed and accepted on 2026-08-11, not overlooked.** The
  mitigation is that the same-repo guard means no code from outside this
  repository reaches the host. The sharpest residual risk is not Cog, whose
  shipped package is dependency-free: it is the _other_ repository sharing
  this runner user, a Rust project whose `cargo build` executes `build.rs`
  from its whole dependency tree as this admin account.

  A dedicated non-admin `cogci` account remains the target state, and the
  full migration procedure is written up. It requires switching auto-login,
  because the simulator lane needs an Aqua session and macOS allows only one
  auto-login user. The revisit triggers below apply with more force because
  of this.

- **Xcode.** Pinned to **26.6**, build **17F113**, installed with `xcodes`
  and selected through `DEVELOPER_DIR`. The hosted `macos-26` arm64 image
  carries the same build and defaults to it, so both lanes compile with an
  identical toolchain rather than merely the same version number. mise cannot
  pin Xcode, hence this record.

  CI finds Xcode by **version and build, never by path**: `xcodes` installs it
  as `/Applications/Xcode.app`, while the hosted image uses
  `/Applications/Xcode_<version>.app`. `tools/select-xcode.mjs` scans the
  installed applications and asks each toolchain for its identity, which is
  the only selection that works in both lanes. Changing the pin means changing
  `COG_XCODE_VERSION` and `COG_XCODE_BUILD` in `swift-ci.yml`, in
  `docs.yml`, and this record together.

  **A full Xcode is required; the Command Line Tools are not enough.** CLT
  carries `swift` and `swift-format`, so building and linting succeed, but
  `swift test` fails with `no such module 'Testing'` — SwiftPM does not wire
  up the CLT copy of `Testing.framework`. This was established by a real CI
  run, after CLT was assumed sufficient and was not.

  Selection uses `DEVELOPER_DIR` rather than `sudo xcode-select` because it
  needs no privilege, so it keeps working under the dedicated non-admin
  runner user this section still targets, and because it is job-scoped, so
  two concurrent jobs cannot fight over a machine-wide setting.

  **Floor simulator runtime.** `M2-18a` selected iOS **17.5**, build
  **21F79** as the intended floor component. Xcode 26.6 supports iOS 15+
  simulator runtimes, and Apple's catalog still lists this build, but that
  catalog entry does not amount to a reproducible install path. On 2026-08-12,
  the real runner's pinned Xcode rejected exact-build downloads with both
  `arm64` and `universal` architecture variants as unavailable. The catalog's
  raw artifact also redirects unauthenticated requests.

  The project owner therefore retired the floor-runtime requirement on
  2026-08-12 and accepted the current simulator lane as the compatibility gate
  for now. There is no iOS 17 nightly. Restoring floor-runtime coverage is new
  work: first establish a reliable runtime without making CI depend on a
  personal Apple Account or an unverified artifact URL, then qualify it with
  an import, boot, reboot, and focused boundary run on `homemac` before
  enabling a nightly. Preserve any future exported recovery copy outside
  runner work and temp directories.

- **Runners.** _Amended 2026-08-11 to match the provisioned host._ One
  runner, `homemac`, **repository-scoped to `skeswa/cog`** so no other
  repository can target it, with its own `_work`. It runs as a launchd
  LaunchAgent installed by `svc.sh install` and bootstrapped into `gui/501`,
  so it starts at login and survives a reboot. The same host and user also
  run a second runner for another repository, which is why the scrub below is
  carefully scoped.
- **Labels.** Registered with `--labels cog-mini`, keeping the default
  `self-hosted`, `macOS`, and `ARM64`. Jobs use
  `runs-on: [self-hosted, macOS, ARM64, cog-mini]`. Label matching is
  cumulative, so the distinctive `cog-mini` term stops a copied
  `runs-on: self-hosted` elsewhere from landing here. No runner group —
  runner groups do not exist for repository-scoped runners on a personal
  account.
- **Scrub hygiene** replaces VM ephemerality. Installed and verified in CI
  on 2026-08-10 as `actions-runner-cog/hooks/{job-started,job-completed}.sh`,
  wired through the runner's `.env`. Checkout uses
  `persist-credentials: false` and `clean: true`.

  `ACTIONS_RUNNER_HOOK_JOB_COMPLETED` removes the job's `RUNNER_WORKSPACE`,
  empties `RUNNER_TEMP`, and deletes `DerivedData/cog-*`. It is deliberately
  **narrower than first specified**: it does not touch `$TMPDIR` or
  `~/Library/Caches/org.swift.swiftpm`, because the runner user also hosts
  another repository's runner and wiping shared state could break a job
  running concurrently next door. Nothing removed belongs to anything but
  cog. Removing the workspace costs no caching, because `actions/cache`
  uploads in its post step, before this hook.

  `ACTIONS_RUNNER_HOOK_JOB_STARTED` fails the job if `GITHUB_WORKSPACE` is
  not empty before checkout, so a scrub that silently stops working halts the
  next run instead of letting it build on an unknown tree. It asserts on the
  _checkout directory_ specifically: the runner pre-creates both
  `RUNNER_WORKSPACE` and the checkout directory inside it, so "absent" and
  "empty workspace" are both always false and neither can be asserted.

  The completed hook never exits non-zero — a failed scrub must not fail an
  otherwise good job — because the started hook is what turns a missed scrub
  into a loud failure at the next opportunity, before any code is built.

- **Concurrency.** Two jobs, by policy rather than by platform limit. The M5
  benchmark job must serialize against everything else on the mini through a
  workflow `concurrency:` group, or its numbers will carry contention noise.

Fork pull requests never reach the mini. Every self-hosted job carries a
same-repo guard, and an approval-gated GitHub-hosted `macos-26` lane covers
forks. The two conditions are exhaustive and mutually exclusive, so exactly
one ordinary macOS lane runs per pull-request or push event:

```yaml
# Self-hosted lane.
if: >-
  github.repository == 'skeswa/cog'
  && (github.event_name != 'pull_request'
      || github.event.pull_request.head.repo.full_name == github.repository)

# Approval-gated GitHub-hosted lane.
if: >-
  github.event_name == 'pull_request'
  && github.event.pull_request.head.repo.full_name != github.repository
```

M8 adds one manual release-artifact exception, bounded to same-repository
`workflow_dispatch` events. The mini builds and checksums both CogLint
executables under pinned Xcode 26.6 and proves the arm64 member. Xcode 26.6's
host SwiftPM driver is arm64-only, so a dependent GitHub-hosted
`macos-15-intel` job downloads that exact SHA-named archive, independently
checks its provenance and checksum, selects the image's Xcode 26.3 build
17C529 (an Intel Swift-tools 6.2 host matching CogLintPlugins), and proves
x86_64 selection without rebuilding. This is a consumer proof, not a third
build toolchain or a path by which pull-request code can reach the mini.

The `event_name != 'pull_request' ||` clause matters: on `push` and
`schedule` there is no `github.event.pull_request`, so a bare comparison
would evaluate false and silently skip the job.

Recorded risks, to revisit rather than forget:

- Bare metal has **no isolation boundary between jobs**. The mitigation is
  the scrub hooks plus the same-repo guard. **If Cog ever grants push access
  to co-maintainers, or the same-repo guard is relaxed, this decision must be
  revisited.**
- A compromised dependency with a build plugin or build script would execute
  as the runner user. `Package.resolved` is committed and reviewed and Cog's
  shipped package is dependency-free, but the runner user is shared with a
  Rust project whose dependency build scripts run arbitrary code. The
  residual risk is accepted, not removed.
- The Virtualization.framework limit of two concurrent macOS guests is
  asserted by the macOS Tahoe 26 SLA and by pre-2026 reports, but **no
  2026-dated primary source re-tests it on macOS 26**. Verify empirically
  before ever taking the VM path.
- `ghcr.io/cirruslabs/macos-tahoe-xcode:26.6` does not exist despite a `26.6`
  template release; the per-Xcode image cadence appears to have lapsed after
  the OpenAI transition. A future VM path should budget for building images
  locally.
- Simulator throughput inside a Tart VM is **unmeasured**. Bare metal defuses
  this for M2, since the simulator lane runs on the host directly.
- The mini's SSD capacity has not been confirmed. Bare metal needs roughly
  40–60 GB; the VM path needs 210–350 GB.

## Actions fork security

This repository is public and its CI is pull-request-driven, so macOS jobs on
the self-hosted runner are protected by layered settings rather than by
omitting the `pull_request` trigger. Three repository-level Actions settings
are part of that hardening. The fork and pinning settings were applied on
2026-08-10; the Release Please permission was enabled on 2026-08-21. These are
the recorded values; verify them with these exact commands:

```sh
# 1. Approval required for workflow runs from all external contributors.
gh api repos/skeswa/cog/actions/permissions/fork-pr-contributor-approval
#    => {"approval_policy":"all_external_contributors"}

# 2. Actions must be pinned to a full-length commit SHA.
gh api repos/skeswa/cog/actions/permissions --jq '.sha_pinning_required'
#    => true

# 3. The default GITHUB_TOKEN is read-only; Actions may create release PRs.
gh api repos/skeswa/cog/actions/permissions/workflow
#    => {"default_workflow_permissions":"read","can_approve_pull_request_reviews":true}
```

These settings are the repository half of the hardening. The workflow half —
the same-repo guard on every self-hosted job, least-privilege `permissions:`
blocks, `persist-credentials: false`, and job timeouts — lives in the
workflows themselves and is enforced by `mise run workflows:check`.

## Repository release controls

Cog permits rebase merging only: merge commits and squash merging are disabled
at the repository level. Bare release tags are protected by the active
`Protect immutable release tags` tag ruleset, whose update and deletion rules
have no bypass actors. Tag creation remains available to Release Please; after
creation, neither a person nor a workflow can move or delete that identity.
The sibling repository has the same tag ruleset and retains read-only default
workflow permissions.

The `cog-release` and sibling `coglint-release` environments each require
`skeswa` as a reviewer and permit self-review. Only their narrow hosted
publisher jobs name those environments or receive `contents: write`.

The existing `Protect main` branch ruleset is migrated only after GitHub has
registered the new `Conventional Commits` check. Its final state requires a
pull request, linear history, the rebase merge method, and that exact status
context. During the one-time migration, PR #400 lands first under the old
deletion/non-fast-forward rules; the child release-management PR then registers
the check before the ruleset is tightened. This ordering avoids requiring a
status that the still-open parent revision cannot produce.

Every write grant is written down rather than waived. `PERMISSION_EXCEPTIONS`
in `tools/lib/workflows/checks.mjs` names the exact workflow, job, scope, and
value: Pages deployment has `pages: write` and `id-token: write`; Release Please
has `contents`, `pull-requests`, and `issues` write; recovery and the docs handoff
have `actions: write`; and the protected publisher has `contents: write`. The
sibling fixture permits only its protected publisher's `contents: write`.

Every exception applies only to a GitHub-hosted job, so a write-scoped token
never reaches the persistent Mac mini. Moving one of those jobs to `cog-mini`
turns its exception off. The workflow checker also requires the `cog-release`
and `coglint-release` environments, the Release Please and action SHAs, exact
candidate identity and provenance checks, tag-bound recovery, explicit docs
dispatch, unchanged sibling `main`, non-forced tag creation, and final public
consumption. Fixtures cover the valid topology and drift at each boundary.

## Release and change-management workflows

The authoritative revision-authoring and range-selection contract is the
[change-management process](./changes.md). This runbook records the workflow's
place in the wider Actions security boundary.

`conventional-commits.yml` is a required, read-only hosted check with no path
filters. It checks out the PR head rather than GitHub's synthetic merge commit
and lints every commit in the PR or push range. The same command reads non-empty
jj descriptions from `main..@` for developer preflight. Commitlint is locked in
the documentation dependency tree; `package.json` remains the private docs
package at 0.0.0 and is not a Cog version source.

`swift-ci.yml` accepts a required Release Please PR number on manual dispatch.
An ordinary candidate must be dispatched at that PR's exact current head. A
recovery candidate must be dispatched at an existing tag and must have the same
tree as the merged release PR. The self-hosted arm64 job builds both native
CogLint binaries and records versioned JSON provenance; the hosted Intel job
downloads those bytes, recomputes the checksum, executes the x86_64 member, and
retains the publication artifact for 90 days. `Release candidate` depends on
the PR-range Conventional Commit check and the complete host, simulator,
examples, Storefront UI, lint, documentation, ledger, benchmark, and artifact
graph. That hosted PR-range job also supplies the required status context for a
Release Please PR whose repository-token creation did not emit an ordinary
pull-request workflow event.

`release.yml` has four hosted jobs with separate tokens. Release Please checks
out no code. Recovery can dispatch and wait for tag-bound Swift CI. Publication
waits at `cog-release`, verifies the successful workflow identity, PR and tag
trees, provenance, architectures, toolchains, and checksum, then publishes only
byte-identical assets. The last job can only dispatch Docs at the published tag.
The sibling repository mirrors the split with read-only preparation, a
`coglint-release`-protected contents writer that executes no downloaded Cog
code, atomically advances `main` with its matching immutable tag, and a final
read-only public consumer.

## The documentation site

`docs.yml` publishes `skeswa.github.io/cog/`. It replaced `swift-docs.yml`,
which published the DocC archive alone.

A repository gets one GitHub Pages deployment and `actions/deploy-pages`
replaces it wholesale, so the site's two halves — the VitePress site built from
`docs/` and the DocC archive built from the Swift sources — are merged into one
artifact by `tools/assemble-docs-site.mjs` before publication. That script's
header records why the overlay is safe and which routes it asserts.

Four jobs, in the order they run:

| Job          | Runner        | Does                                                                             |
| ------------ | ------------- | -------------------------------------------------------------------------------- |
| `docc-cache` | hosted ubuntu | Resolves the newest release tag and asks whether a DocC archive for it is cached |
| `docc`       | `cog-mini`    | Builds that archive — **only on a cache miss**                                   |
| `assemble`   | hosted ubuntu | Installs npm dependencies, builds VitePress, merges, uploads the Pages artifact  |
| `deploy`     | hosted ubuntu | Publishes the artifact, and nothing else                                         |

Three properties of that split are deliberate.

**The API reference always describes a release, never `main`.** The `docc` job
checks out the newest release tag rather than the commit being published, so
pushing prose to `main` republishes the site around an unchanged API reference.
This preserves what `M4-05c` guaranteed when deployment was tag-gated.

**An ordinary documentation change does not wake the Mac mini.** `docc-cache`
runs on a hosted runner and only probes the cache; the mini is scheduled solely
on a miss. A cache entry is scoped to the ref that created it, so the first push
to `main` after a release misses and rebuilds once, and every push after that
hits.

**The job that runs third-party code is not the job that holds the token.**
`assemble` executes `npm ci`, so it is deliberately read-only; `deploy` holds
the `pages: write` and `id-token: write` grant and consists of a single action
invocation with no repository code in it.

`docs.yml` has no `paths:` filter, and should not gain one. Ordinary pushes can
still republish prose, while the release pipeline explicitly dispatches Docs at
the published tag. That dispatch is load-bearing: the repository token creates
the Release Please tag, and token-created push events do not generally start a
second workflow.

If the site is ever published without its API reference, `assemble` has failed
to find the archive; re-running the workflow rebuilds it on the mini. The merge
script fails closed rather than deploying a site that 404s its own
`documentation/cog/` routes.
