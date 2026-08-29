# Cog CI and runner operations

_August 21, 2026._

This runbook defines Cog's runners, workflow permissions, and repository
settings. `mise run workflows:check` checks the workflow rules.

## macOS runners

Trusted macOS jobs belong on the `homemac` Apple Silicon Mac mini. Linux jobs
use GitHub-hosted Ubuntu. Fork pull requests use GitHub-hosted `macos-26` and
never reach the mini.

### Temporary hosted topology

**The mini is currently unavailable, so the same-repo macOS lane runs on
GitHub-hosted `macos-26` for now.** The lane's jobs keep their same-repo
guards, cache keys, and structure; only `runs-on:` changed, so restoring the
mini is the reverse label swap in `swift-ci.yml` and `docs.yml`, nothing more.
Three things follow from the hosted period:

- Hosted VMs start cold, so the jobs that leaned on the mini's persistent
  disk (`lint-swift`, `compile-fail`, `build-weather`) carry `actions/cache`
  steps the mini never needed. Leave the caches in place after the swap back;
  they are harmless on the mini.
- The benchmark and UI-performance timing ceilings were recorded on the
  pinned mini, and a shared VM's p90 measures the neighbors — the first
  hosted run proved it when the state-graph comparison blew its ceiling with
  no allocation change anywhere. The hosted `bench-build` job therefore runs
  `bench:thresholds:check --allocations-only`: exact allocation and ARC
  counts still gate every change (they are deterministic across hosts on one
  toolchain), while the wall-clock ceilings are loudly skipped and resume
  when the flag is dropped with the swap back. No committed threshold
  changes during this period; thresholds change only after a pinned-runner
  session.
- Release-candidate provenance records
  `"runner": "github-hosted-macos-26"` for artifacts built in this period.

The rest of this section describes the mini so it can return exactly as it
left.

The mini uses persistent bare metal, not a fresh virtual machine for each job.
Job hooks clean Cog files before and after every run. A virtual-machine setup is
a future option, but current personal-repo tools are not maintained well enough
and would need about 210–350 GB of free storage.

### Current host

- **User:** the runner uses the `remembot` admin account on `homemac`. This is
  weaker than a dedicated CI account. That account can reach one SSH key, two
  saved `gh` tokens, the login keychain, and `/opt/homebrew`. It also runs CI
  for a Rust repo whose dependency build scripts can run code. This risk is
  accepted only because outside pull-request code cannot reach the mini.
- **Target state:** move Cog to a dedicated, non-admin `cogci` account. The
  simulator needs a logged-in graphical session, so this move also requires
  changing macOS auto-login.
- **Runner:** `homemac` is limited to `skeswa/cog`, has its own `_work`
  directory, and runs as a launchd LaunchAgent installed with `svc.sh install`
  in `gui/501`. It starts at login and returns after a reboot.
- **Labels:** jobs require `[self-hosted, macOS, ARM64, cog-mini]`. The unique
  `cog-mini` label prevents a broad `self-hosted` job from landing here.
- **Load:** at most two jobs run at once. Benchmark jobs share a workflow
  concurrency group with all other mini jobs so they measure an idle host.

Revisit bare metal before adding another maintainer with push access or letting
outside code pass the same-repo guard. Also check disk space and simulator speed
before moving to virtual machines.

### Xcode

CI uses Xcode **26.6**, build **17F113**, and Swift 6.3.3. The hosted
`macos-26` arm64 image has the same Xcode build.

`tools/select-xcode.mjs` finds Xcode by version and build, not by path. This is
needed because `xcodes` installs `/Applications/Xcode.app`, while hosted images
use a versioned path. Change `COG_XCODE_VERSION`, `COG_XCODE_BUILD`,
`swift-ci.yml`, `docs.yml`, and this page together.

The script sets job-only `DEVELOPER_DIR`; it does not run the system-wide
`xcode-select`. This avoids admin access and prevents two jobs from changing
each other's toolchain.

Use full Xcode. Command Line Tools include `swift` and `swift-format`, but
`swift test` fails there because SwiftPM cannot load `Testing.framework`.

Simulator CI uses the latest runtime in pinned Xcode. The planned iOS 17.5
floor was removed because Xcode could not download its exact build without a
personal Apple account or untrusted artifact URL. To restore floor testing,
first prove a safe install, import, boot, reboot, and focused boundary test on
`homemac`. Keep any recovery copy outside runner work and temp folders.

### Cleanup hooks

The runner loads these scripts through its `.env` file:

```text
actions-runner-cog/hooks/job-started.sh
actions-runner-cog/hooks/job-completed.sh
```

Checkout must use `persist-credentials: false` and `clean: true`.

After a job, the completed hook removes only:

- that job's `RUNNER_WORKSPACE`;
- `RUNNER_TEMP`; and
- `DerivedData/cog-*`.

It must not clear all of `$TMPDIR` or `~/Library/Caches/org.swift.swiftpm`,
because another repo may be using them. Cache uploads finish before this hook.
The hook never fails an otherwise good job.

Before checkout, the started hook fails if `GITHUB_WORKSPACE` is not empty.
The runner always creates the workspace folders, so check that the checkout
directory is empty instead of checking whether it exists. This next-run check
makes a missed cleanup visible before new code runs.

### Fork boundary

Every self-hosted job uses this same-repo check:

```yaml
if: >-
  github.repository == 'skeswa/cog'
  && (github.event_name != 'pull_request'
      || github.event.pull_request.head.repo.full_name == github.repository)
```

Every hosted fork job uses the opposite check:

```yaml
if: >-
  github.event_name == 'pull_request'
  && github.event.pull_request.head.repo.full_name != github.repository
```

The event-name test matters because push and schedule events have no
`pull_request` object.

Manual release candidates are the only extra path into the same-repo lane. Its
arm64 job builds both CogLint macOS executables with Xcode 26.6, checksums the
archive, records its source and tools, and tests arm64. A hosted
`macos-15-intel` job downloads those exact bytes, verifies them, selects Xcode
26.3 build 17C529, and tests the x86_64 file without rebuilding it.
Pull-request code still needs to come from this repository.

## GitHub Actions settings

These repository settings are part of the security boundary:

```sh
# All outside contributors need approval before their workflow runs.
gh api repos/skeswa/cog/actions/permissions/fork-pr-contributor-approval
# => {"approval_policy":"all_external_contributors"}

# Actions must use full commit SHAs.
gh api repos/skeswa/cog/actions/permissions --jq '.sha_pinning_required'
# => true

# Tokens are read-only by default; Actions may create release PRs.
gh api repos/skeswa/cog/actions/permissions/workflow
# => {"default_workflow_permissions":"read","can_approve_pull_request_reviews":true}
```

Workflows must also use clear `permissions` blocks, timeouts, full action SHAs,
`persist-credentials: false`, and the same-repo guard on every job in the
same-repo lane — enforced structurally for any `self-hosted` label, and kept
on the lane's jobs through the hosted period so the topology snaps back.
`mise run workflows:check` enforces these rules.

## Branch, tag, and environment rules

- GitHub allows rebase merging only. Merge commits and squash merging are off.
- The `Protect main` ruleset requires a pull request, linear history, rebase
  merging, and the `Conventional Commits` check.
- The `Protect immutable release tags` ruleset blocks changes and deletion for
  bare release tags, with no bypass. Release Please may create a tag, but no
  person or workflow may later move or delete it.
- The sibling `coglint-plugins` repo uses the same tag rule and read-only
  default token permissions.
- `cog-release` and `coglint-release` each require `skeswa` as reviewer and
  allow self-review. Only their hosted publisher jobs get `contents: write`.

During first setup, let the parent PR land under the old branch rules. Register
the new `Conventional Commits` check with the release-management PR, then add
that check to `Protect main`. A ruleset cannot require a check that GitHub has
not seen.

## Allowed write jobs

`PERMISSION_EXCEPTIONS` in `tools/lib/workflows/checks.mjs` lists every allowed
write grant by workflow, job, permission, and value:

| Job                         | Allowed write access                       |
| --------------------------- | ------------------------------------------ |
| Pages deploy                | `pages`, `id-token`                        |
| Release Please              | `contents`, `pull-requests`, `issues`      |
| Release recovery            | `actions`                                  |
| Docs handoff                | `actions`                                  |
| Protected Cog publisher     | `contents`                                 |
| Protected sibling publisher | `contents` in the sibling workflow fixture |

These exceptions work only on GitHub-hosted jobs. A write token must never
reach the Mac mini. The workflow checker also tests the protected environments,
action SHAs, exact candidate identity, source records, recovery, docs dispatch,
unchanged sibling `main`, safe tag creation, and final public plugin use.

## Main workflows

### Commit messages

`conventional-commits.yml` is a required hosted check with `contents: read` and
no path filters. It checks every commit in the pull-request or push range. See
[change management](./changes.md) for message rules and local checks.

### Swift CI and release candidates

`swift-ci.yml` accepts a Release Please PR number for a manual candidate. The
dispatch ref must equal that PR's current head. Recovery instead uses an
existing tag whose tree matches the merged release PR.

The arm64 job creates a versioned CogLint archive and JSON record. The hosted
Intel job tests the same bytes and keeps the publication artifact for 90 days.
The final `Release candidate` job requires all commit, format, host, simulator,
example, Storefront, lint, docs, task, benchmark, and artifact jobs. Its hosted
commit check also supplies the required result for a bot-created release PR.

### Release publication

`release.yml` keeps four hosted jobs and four separate tokens:

1. Release Please creates or updates the release PR without checking out code.
2. Recovery may dispatch and wait for tag-bound Swift CI.
3. The `cog-release` publisher verifies the candidate, source trees, tools,
   architectures, record, and checksum before publishing matching bytes.
4. A narrow `actions: write` job dispatches Docs at the published tag.

The sibling repo uses the same split. Read-only preparation builds and checks
the generated package. The `coglint-release` writer runs no downloaded Cog code,
requires sibling `main` to be unchanged, pushes without force, and creates the
matching tag. A final read-only job uses that public tag.

## Documentation workflow

`docs.yml` combines the VitePress site from `docs/` with the DocC API reference.
GitHub Pages supports one deployment, so `tools/assemble-docs-site.mjs` merges
both outputs and checks their required routes.

| Job          | Runner        | Work                                                             |
| ------------ | ------------- | ---------------------------------------------------------------- |
| `docc-cache` | hosted Ubuntu | Resolve the newest published release and find its DocC archive   |
| `docc`       | macOS lane    | Build that archive only when it is missing                       |
| `assemble`   | hosted Ubuntu | Build VitePress, merge both sites, and upload the Pages artifact |
| `deploy`     | hosted Ubuntu | Publish the artifact; run no repository code                     |

The API reference and VitePress release labels always describe GitHub's newest
published release, not `main`, a draft tag, or the workflow's source ref. A
normal docs change does not wake the macOS lane when that release archive is
already saved. The saved archive belongs to the ref that created it, so the
first `main` push after a release builds it once; later pushes reuse it.
The `assemble` job runs third-party npm code with a read-only token. Only the
single-action `deploy` job receives `pages: write` and `id-token: write`.

Do not add a path filter to `docs.yml`. The release workflow must dispatch it
at the tag because events made by a repository token do not usually start
another workflow. If the API reference is missing, rerun Docs; the merge step
will fail instead of publishing broken `/documentation/cog/` links.

## Open questions

These are unresolved operational choices, not defects. Each is written down so
a future change reconsiders it deliberately.

- If the mini ever moves from bare metal to a virtual machine, measure
  benchmark noise again before trusting a gated threshold from the new host.
- Recheck the benchmark tool pins in `swift/Benchmarks/Runner/README.md` whenever
  Swift or Xcode changes.
- Move simulator checks out of pull requests if they become too slow, and run
  them on `main` and release candidates only.
