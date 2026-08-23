# Cog

Cog is fine-grained state management for native mobile apps:

- **iOS:** a working Swift library for SwiftUI. It uses `@Observable` at the UI
  edge and one app-wide state graph on the MainActor.
- **Android:** a planned Kotlin library for Jetpack Compose. It will use one
  app-wide store over the Compose snapshot system.

Both libraries follow one [shared state model](./docs/design.md), but each uses
the normal tools and style of its platform.

## Core rules

1. **Keep it simple.** State should be easy to declare, read, and change.
2. **Make every read correct.** A read must use the last complete change and
   update all values it depends on first.
3. **Keep overhead low.** Avoid extra work, memory use, locks, and UI updates.
   Use benchmarks to choose internal designs.
4. **Keep one source of truth.** One running app has one Cog graph. Each mutable
   fact has one writable source in that graph.

Speed must not weaken correctness or create more sources of truth.

## Status

The Swift library is ready to use. It includes SwiftUI support, app-wide side
effects, lifetimes, async work, streams, value exports, Observation support,
CogLint plugins, and a fast specialized arena. Normal graph notices scale with
the number of changed values, and steady turns do not allocate memory. Apps can
use `CompactArena` to reduce binary size. The Storefront benchmark tests the
full design. Android work has not started.

<!-- x-release-please-start-version -->

The current Swift release is 0.4.0.
<!-- x-release-please-end -->

See the [Swift context guide](./docs/swift/README.md#production-tests-and-previews)
for production, test, and preview setup. See [CHANGELOG.md](./CHANGELOG.md) for
release details.

The old Dart and Flutter experiment is no longer in the current tree. The
[design history](./docs/history.md) explains the few ideas needed to understand
today's model. The full experiment remains in repository history.

## Add Cog to a Swift app

Cog has no runtime dependencies. Add it to `Package.swift`:

```swift
// x-release-please-start-version
dependencies: [
  .package(
    url: "https://github.com/skeswa/cog.git",
    .upToNextMinor(from: "0.4.0")
  )
]
// x-release-please-end
```

In Xcode, add the same URL through **File ▸ Add Package Dependencies** and
choose **Up to Next Minor Version**.

The default uses the fastest measured design. A final app can trade some speed
for a smaller binary:

```swift
// x-release-please-start-version
.package(
  url: "https://github.com/skeswa/cog.git",
  exact: "0.4.0",
  traits: ["CompactArena"]
)
// x-release-please-end
```

Package traits affect every package that resolves Cog. Only the final app
should enable `CompactArena`; a library should not choose it for its users. The
trait changes no public behavior or API.

Pin to a **minor**, not a major. Before 1.0, a minor release may include listed
breaking changes. A patch release only adds or fixes behavior.

Use the `Cog` product in app targets. Use `CogTesting` in tests and preview
support. Cog requires iOS 17 or macOS 14 and Swift tools 6.2. Releases are
tested with Xcode 26.6 and Swift 6.3.3.

Read [Getting Started](https://skeswa.github.io/cog/documentation/cog/gettingstarted)
to put a value on screen. Read
[Linting your app](https://skeswa.github.io/cog/documentation/cog/lintingyourapp)
to add the separate, version-matched CogLint plugins without adding lint tools
to normal Cog users.

## Work on Cog

[CONTRIBUTING.md](./CONTRIBUTING.md) covers setup, tests, docs, and the Jujutsu
workflow. [mise](https://mise.jdx.dev) manages tools; `mise tasks` lists every
command.

Every release step runs in GitHub Actions. Release Please reads Conventional
Commit messages to choose the next version and write the changelog. Protected
workflows test and publish Cog, its docs, and the matching `coglint-plugins`
tag. Start with [change management](./docs/maintainers/changes.md). Maintainers
should also read [CI operations](./docs/maintainers/ci.md) and the
[Swift release runbook](./docs/maintainers/releasing.md).

## Documentation

The full site is [skeswa.github.io/cog](https://skeswa.github.io/cog/). Key
pages are also available here:

- [Changelog](./CHANGELOG.md) — changes in each Swift release
- [Contributing](./CONTRIBUTING.md) — setup, checks, tests, docs, and revisions
- [Security](./SECURITY.md) — supported releases and private reports
- [Change management](./docs/maintainers/changes.md) — commit rules and checks
- [CI operations](./docs/maintainers/ci.md) — runners, permissions, and controls
- [Release runbook](./docs/maintainers/releasing.md) — the Actions-only release
- [Shared state model](./docs/design.md) — rules shared by Swift and Kotlin
- [Design history](./docs/history.md) — useful background from the old design
- [Swift docs](./docs/swift/README.md) — current Swift design and work
- [Kotlin docs](./docs/kotlin/README.md) — planned Kotlin and Compose design
