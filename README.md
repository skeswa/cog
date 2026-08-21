# Cog

Cog is a fine-grained state-management project for native mobile UI. It is
planned as two platform-native libraries:

- **iOS:** a Swift library for SwiftUI, using `@Observable` at the UI boundary
  and one app-wide MainActor-confined dependency graph inside.
- **Android:** a Kotlin library for Jetpack Compose, built first over the
  Compose snapshot runtime with one app-wide store plus turn, lifetime, and
  async rules.

The libraries implement one [shared state model](./docs/design.md), while each
fits its platform instead of forcing one platform's API onto the other.

## Design principles

1. **Cog should feel simple.** Declaring, reading, and changing state should
   look natural on each platform. Common code should be easy to read and
   reason about.
2. **Every state read should be correct.** A read must use the latest completed
   source state after settling every dependency it needs. It must not expose a
   torn update, stale automatic value, or half-finished change.
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

The Swift library is real and usable. Releases through 0.4.0 include the
original simple core, SwiftUI boundary, mechanisms, declared lifetimes, async
policies and streams, value exports, the external Observation bridge, and
first-party CogLint plugins. Post-release performance work has made graph
notices O(changed), removed steady-turn allocations from shared machinery, and
added a representative Storefront workload. On `main`, the specialized arena
is the sole core and the default implementation. Applications that prioritize
binary size can explicitly disable its typed specialization frontier with the
non-default `CompactArena` package trait. The Android library has not been
started.

The [Swift context guide](./docs/swift/README.md#production-tests-and-previews)
shows the production-bootstrap and isolated-test call sites, and
[CHANGELOG.md](./CHANGELOG.md) records what each release contains.

The earlier Dart and Flutter experiment has been removed from the current
tree. [Design history](./docs/history.md) carries forward its motivation,
decisions, and source trail; the complete dump remains in repository history.

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

The default above selects the fastest measured implementation: specialized
arena with shared pool edges. That change and `CompactArena` are new on `main`
and are not part of 0.4.0. Once consuming a release or revision that contains
them, a final application can opt out of typed specialization with the
trait-aware dependency overload. For example, if it ships in 0.5.x:

```swift
.package(
  url: "https://github.com/skeswa/cog.git",
  "0.5.0"..<"0.6.0",
  traits: ["CompactArena"]
)
```

Package traits are additive across the dependency graph. Enable this trait
only when the final application owns the binary-size decision; a reusable
library should not force the compact configuration on every application that
also resolves Cog. The trait changes no Cog API or behavior and does not
restore the retired simple core. It keeps the arena and shared edge pool while
suppressing the client-specializable typed value frontier.

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
authoritative command list. Maintainer-only details live in the
[CI operations](./docs/maintainers/ci.md) and
[Swift release](./docs/maintainers/releasing.md) runbooks.

## Documentation

Everything below is published as a website at
**[skeswa.github.io/cog](https://skeswa.github.io/cog/)**, with search and
navigation, alongside the generated API reference. The same documents are
readable in this repository.

- **[CHANGELOG.md](./CHANGELOG.md):** what changed in each Swift release, and
  what a 0.x minor is allowed to break.
- **[CONTRIBUTING.md](./CONTRIBUTING.md):** local setup, verification, test
  organization, and revision conventions.
- **[SECURITY.md](./SECURITY.md):** supported releases and private
  vulnerability reporting.
- **[CI and runner operations](./docs/maintainers/ci.md):** the maintainer
  runbook for the self-hosted boundary, hosted fork lane, and workflow
  hardening contract.
- **[Releasing Cog for Swift](./docs/maintainers/releasing.md):** candidate,
  annotated-tag, publication, and post-release verification steps.
- **[Shared state model](./docs/design.md):** the problem, vocabulary, and
  behavioral invariants both platform libraries implement.
- **[Design history](./docs/history.md):** the Dart and Flutter lineage, how the
  model evolved, what survived, and the original source trail.
- **[Swift design](./docs/swift/README.md):** the reading order, current
  decisions, open questions, and implementation plan for SwiftUI.
- **[Kotlin design](./docs/kotlin/README.md):** the reading order, Compose
  snapshot architecture, worked example, Flow and effects guidance, and
  Android benchmark plan.
