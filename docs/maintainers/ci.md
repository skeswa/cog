# Cog CI and runner operations

_August 20, 2026._

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

  CI finds Xcode by **version, never by path**: `xcodes` installs it as
  `/Applications/Xcode.app`, while the hosted image uses
  `/Applications/Xcode_<version>.app`. Every job scans `/Applications/
Xcode*.app` and reads each bundle's `version.plist`, which is the only
  spelling that works in both lanes. Changing the pin means changing
  `COG_XCODE_VERSION` in `swift-ci.yml`, in `swift-docs.yml`, and this record
  together.

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
are part of that hardening. They were applied on 2026-08-10 and are the
recorded values below; verify them with these exact commands:

```sh
# 1. Approval required for workflow runs from all external contributors.
gh api repos/skeswa/cog/actions/permissions/fork-pr-contributor-approval
#    => {"approval_policy":"all_external_contributors"}

# 2. Actions must be pinned to a full-length commit SHA.
gh api repos/skeswa/cog/actions/permissions --jq '.sha_pinning_required'
#    => true

# 3. The default GITHUB_TOKEN is read-only and cannot approve pull requests.
gh api repos/skeswa/cog/actions/permissions/workflow
#    => {"default_workflow_permissions":"read","can_approve_pull_request_reviews":false}
```

These settings are the repository half of the hardening. The workflow half —
the same-repo guard on every self-hosted job, least-privilege `permissions:`
blocks, `persist-credentials: false`, and job timeouts — lives in the
workflows themselves and is enforced by `mise run workflows:check`.

That contract allows exactly one write grant, and it is written down rather
than waived: the `deploy` job of `swift-docs.yml` holds `pages: write` and
`id-token: write`, because GitHub Pages cannot be published with a read-only
token. Two things bound it. The exception names that one file, that one job id,
and those two scopes in `PERMISSION_EXCEPTIONS`
(`tools/lib/workflows/checks.mjs`), so a second job cannot inherit it and an
extra scope on the same job still fails. And it is granted only to a
GitHub-hosted job, so a write-scoped token never reaches the persistent Mac
mini — moving that job to `cog-mini` turns the exception off rather than
carrying it along. Fixtures cover both the granted case and each way of
overreaching it.
