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

Cog is in the design phase. The Swift and Android designs are detailed enough
to begin their correctness and performance spikes. Neither library is
implemented yet.

The earlier Dart and Flutter experiment has been removed from the current
tree. It remains available in the repository history.

## Continuous integration

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

## Documentation

- **[Swift design](./docs/swift/README.md):** the reading order, current
  decisions, open questions, and implementation plan for SwiftUI.
- **[Kotlin design](./docs/kotlin/README.md):** the reading order, Compose
  snapshot architecture, worked example, Flow and effects guidance, and
  Android benchmark plan.
- **[Dart and Flutter design snapshot](./docs/dump-2026-08-06.md):** frozen
  historical context. It is not normative for either current library.
