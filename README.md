<h1>
  <picture>
    <source
      media="(prefers-color-scheme: dark)"
      srcset="./docs/public/cog-lockup-dark.svg"
    />
    <source
      media="(prefers-color-scheme: light)"
      srcset="./docs/public/cog-lockup-light.svg"
    />
    <img src="./docs/public/cog-lockup-light.svg" alt="Cog" height="72" />
  </picture>
</h1>

Cog is fine-grained state management for native mobile apps:

- **iOS:** a working Swift library for SwiftUI. It uses `@Observable` at the UI
  edge and one app-wide state graph on the MainActor.
- **Android:** a planned Kotlin library for Jetpack Compose. It will use one
  app-wide Cog graph, with Compose state carrying UI invalidation.

Both libraries implement one [shared runtime model](./docs/design.md). Each
uses the names and native UI tools of its platform.

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
use `CompactArena` to reduce binary size. The Storefront macrobenchmark tests
the full design against three alternatives — plain `@Observable` with no
caching, hand-written caching, and swift-state-graph — by running all four
through one identical shopping session, and every runtime has to compute the
same answers before any timing is reported. The measured
[cross-runtime results](./docs/swift/impl/perf.md#cross-runtime-results)
say what Cog's machinery costs and what it buys. Android work has not started.

<!-- x-release-please-start-version -->

The current Swift release is 0.6.1.
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
    .upToNextMinor(from: "0.6.1")
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
  exact: "0.6.1",
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

Read [Getting started](https://skeswa.github.io/cog/swift/getting-started)
to put a value on screen. Read
[Linting your app](https://skeswa.github.io/cog/documentation/cog/lintingyourapp)
to add the separate, version-matched CogLint plugins without adding lint tools
to normal Cog users.

## Use Cog with a coding agent

Agents do not read a dependency's docs on their own. Point yours at the
one-page brief, [Cog for coding agents](https://skeswa.github.io/cog/swift/agent-guide),
which states the model, the recurring code shapes, and the conventions
`coglint` enforces. Three ways, from cheapest to most complete:

**Add two lines to your instruction file.** This works for every agent that
reads `AGENTS.md`, `CLAUDE.md`, `.github/copilot-instructions.md`, or a
Cursor rule:

```markdown
State management is Cog. Before writing or changing state, read
https://skeswa.github.io/cog/swift/agent-guide.md and follow it. Run
`swift package coglint Sources --target-role production` before finishing.
```

**Install the skill.** It carries the same page plus the handbook chapters as
references, and works in Claude Code, Codex, Cursor, Copilot, Gemini CLI, and
the other agents the installer supports:

```sh
npx skills add skeswa/cog
```

Claude Code can install it as a plugin instead:

```text
/plugin marketplace add skeswa/cog
/plugin install cog@cog
```

**Give the agent the whole site.** Every page has a Markdown twin at the same
URL with `.md` appended, `https://skeswa.github.io/cog/llms.txt` indexes them,
and the repository carries a `context7.json` so agents using the Context7 MCP
server get the handbook on demand.

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
- [Swift handbook](./docs/swift/handbook/index.md) — the working conventions for
  building an app on Cog, with chapters from file layout to testing
- [Cog for coding agents](./docs/swift/agent-guide.md) — the handbook, its
  recurring code shapes, and the lint rules on one page for a coding model
- [Kotlin docs](./docs/kotlin/README.md) — planned Kotlin and Compose design
- [TodoMVC example](./swift/Examples/TodoMVC/README.md) — a complete native
  SwiftUI app demonstrating keyed state, derived filters, atomic actions, and persistence
- [Trails example](./swift/Examples/Trails/README.md) — a tabbed SwiftUI app
  whose navigation, deep linking, and restoration are all driven by graph state
- [Storefront macrobenchmark](./swift/Benchmarks/Storefront/README.md) —
  the four-runtime comparison and how to run it
