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

The Swift library is real and usable. Releases through 0.4.0 include the simple
shipping core, SwiftUI boundary, mechanisms, declared lifetimes, async policies
and streams, value exports, the external Observation bridge, and first-party
CogLint plugins. Post-release performance work has made graph notices
O(changed), removed steady-turn allocations from shared machinery, and added a
representative Storefront workload. The faster arena core remains an internal
research candidate while its keyed construction and specialization tradeoffs
are resolved. The Android library has not been started.

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
    .upToNextMinor(from: "0.4.0")
  )
]
```

or, in Xcode, add the same URL under **File ▸ Add Package Dependencies** with
the **Up to Next Minor Version** rule.

Pin to a **minor**, not a major. Cog is in 0.x, where a minor release may break
source compatibility and says so in the changelog, while a patch release only
adds or fixes. `.upToNextMajor` would take those breaking minors silently.

Depend on the `Cog` product from an app target, and on `CogTesting` from test
and preview-support targets. Cog requires iOS 17 or macOS 14. Its manifest uses
Swift tools 6.2; the repository currently builds and tests releases with Xcode
26.6 and Swift 6.3.3.
The documentation lives at
[skeswa.github.io/cog](https://skeswa.github.io/cog/documentation/cog/), and
[Getting Started](https://skeswa.github.io/cog/documentation/cog/gettingstarted)
takes an app from this pin to a value on screen.
[Linting your app](https://skeswa.github.io/cog/documentation/cog/lintingyourapp)
shows how to add the separately distributed, version-matched CogLint plugins
without adding lint dependencies to an ordinary Cog consumer.

## Working in this repository

[CONTRIBUTING.md](./CONTRIBUTING.md) covers setup, guarded test commands, the
test topology, documentation obligations, and the Jujutsu workflow. Tooling is
versioned with [mise](https://mise.jdx.dev), and `mise tasks` prints the
authoritative command list. Maintainer-only runner and release details live in
[docs/maintainers/ci.md](./docs/maintainers/ci.md).

## Documentation

- **[CHANGELOG.md](./CHANGELOG.md):** what changed in each Swift release, and
  what a 0.x minor is allowed to break.
- **[CONTRIBUTING.md](./CONTRIBUTING.md):** local setup, verification, test
  organization, and revision conventions.
- **[SECURITY.md](./SECURITY.md):** supported releases and private
  vulnerability reporting.
- **[CI and runner operations](./docs/maintainers/ci.md):** the maintainer
  runbook for the self-hosted boundary, hosted fork lane, and workflow
  hardening contract.
- **[Swift design](./docs/swift/README.md):** the reading order, current
  decisions, open questions, and implementation plan for SwiftUI.
- **[Kotlin design](./docs/kotlin/README.md):** the reading order, Compose
  snapshot architecture, worked example, Flow and effects guidance, and
  Android benchmark plan.
- **[Dart and Flutter design snapshot](./docs/dump-2026-08-06.md):** frozen
  historical context. It is not normative for either current library.
