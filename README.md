# Cog

Cog is a fine-grained state-management project for native mobile UI. It is
planned as two platform-native libraries:

- **iOS:** a Swift library for SwiftUI, using `@Observable` at the UI boundary
  and one app-wide MainActor-confined dependency graph inside.
- **Android:** a Kotlin library for Jetpack Compose, built first over the
  Compose snapshot runtime with one app-wide store plus turn, lifetime, and
  async rules.

The two libraries will share the same goals, but each should fit its platform
instead of forcing one platform's API onto the other.

## Design principles

1. **Cog should feel simple.** Declaring, reading, and changing state should
   look natural on each platform. Common code should be easy to read and
   reason about.
2. **Every state read should be correct.** A read must use the latest committed
   source state after settling every dependency it needs. It must not expose a
   torn update, stale derived value, or half-finished change.
3. **Cog should minimize runtime overhead.** Avoid needless recomputation,
   allocation, synchronization, and UI updates. Use benchmarks to choose
   implementation details.
4. **Cog state should be singular.** One running app has one authoritative Cog
   graph, and each mutable fact represented in Cog has one writable source in
   it. Screens and features must not create competing graphs or mirror
   sources. Tests and previews are separate runtimes, each with one graph.

Correctness and singular state are not traded for speed. Performance work
should also keep the common API simple.

## Status

The Swift library is real and usable. The simple correctness core, the SwiftUI
boundary, mechanisms, declared lifetimes, and the first async slice have all
landed, with the Weather example app built on them; the benchmark port and the
data-oriented performance core remain ahead. The Android library has not been
started.

The [Swift context guide](./docs/swift/README.md#production-tests-and-previews)
shows the production-bootstrap and isolated-test call sites, and
[CHANGELOG.md](./CHANGELOG.md) records what each release contains.

The earlier Dart and Flutter experiment has been removed from the current
tree. It remains available in the repository history.

## Using Cog in an app

Cog for Swift resolves with no dependencies of its own. Add it to a
`Package.swift`:

```swift
dependencies: [
  .package(
    url: "https://github.com/skeswa/cog.git",
    .upToNextMinor(from: "0.1.0")
  )
]
```

or, in Xcode, add the same URL under **File ▸ Add Package Dependencies** with
the **Up to Next Minor Version** rule.

Pin to a **minor**, not a major. Cog is in 0.x, where a minor release may break
source compatibility and says so in the changelog, while a patch release only
adds or fixes. `.upToNextMajor` would take those breaking minors silently.

Depend on the `Cog` product from an app target, and on `CogTesting` from test
and preview-support targets. Cog requires iOS 17 or macOS 14 and Swift 6.2.
The documentation lives at
[skeswa.github.io/cog](https://skeswa.github.io/cog/documentation/cog/), and
[Getting Started](https://skeswa.github.io/cog/documentation/cog/gettingstarted)
takes an app from this pin to a value on screen.

## Working in this repository

Tooling is versioned with [mise](https://mise.jdx.dev); `mise.toml` is the
authoritative list of commands and `mise tasks` prints it. Building and
testing Swift also needs a full Xcode — the version and the reason are in
"Continuous integration" below.

```sh
mise run fmt            # format Markdown, JSON, YAML, and Swift
mise run fmt:check      # verify formatting, writing nothing
mise run test           # Swift tests on the default isolation leg
mise run test:matrix    # all four isolation legs
mise run test:cores     # full suite under the simple and arena cores
mise run test:value-references # all three value-reference layouts
mise run test:release   # the default leg in release configuration
mise run test:simulator # boundary tests on the latest iOS simulator
mise run build:weather  # build the Weather example for the iOS simulator
mise run test:weather   # run the Weather example's tests on a simulator
mise run tasks:check    # validate the Swift implementation task ledger
mise run docs           # build the DocC archive into .build/docs
```

`mise run test:compilefail` type-checks the expected-failure fixtures under
`swift/CompileFail/`, and `mise run workflows:check` validates the GitHub
Actions hardening contract.

Tests always run through the `mise` wrapper rather than `swift test`, because
SwiftPM exits 0 when `--filter` selects nothing and the wrapper fails instead.
Pass arguments straight through:
`mise run test --filter 'DECL-01|ONE-05' --parallel`.

`AGENTS.md` and `CLAUDE.md` carry the full command reference, the repository
layout, and the version-control conventions.

## Continuous integration

### macOS runner topology

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
one macOS lane runs per event:

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

### Actions fork security

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

## Documentation

- **[CHANGELOG.md](./CHANGELOG.md):** what changed in each Swift release, and
  what a 0.x minor is allowed to break.
- **[Swift design](./docs/swift/README.md):** the reading order, current
  decisions, open questions, and implementation plan for SwiftUI.
- **[Kotlin design](./docs/kotlin/README.md):** the reading order, Compose
  snapshot architecture, worked example, Flow and effects guidance, and
  Android benchmark plan.
- **[Dart and Flutter design snapshot](./docs/dump-2026-08-06.md):** frozen
  historical context. It is not normative for either current library.
