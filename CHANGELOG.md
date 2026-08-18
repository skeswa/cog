# Changelog

All notable changes to Cog for Swift are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Cog is in 0.x. A **minor** release may break source compatibility and says so
under a "Breaking" heading; a **patch** release only adds or fixes. Pin
accordingly:

```swift
.package(url: "https://github.com/skeswa/cog.git", .upToNextMinor(from: "0.4.0"))
```

Kotlin releases through Maven coordinates and is not versioned here.

## [0.4.0] - 2026-08-18

Cog conventions are now executable. The first-party `coglint` binary ships
behind opt-in SwiftPM plugins while the Cog library itself continues to
resolve with no dependencies.

### Breaking

- No intentional source-breaking library change. Existing 0.3.0 declarations,
  async policies, streams, exports, and external Observation tracking retain
  their spellings and semantics.

### Added

- The syntax-only `coglint` CLI with deterministic recursive path discovery,
  exact source locations, explicit production and test target roles, Xcode,
  GitHub, and SARIF reporters, and reason-bearing next-line suppression. The
  opt-in build-tool plugin fails a build on findings; every diagnostic links
  to its rule article and its expected repair.
- Six initial convention rules covering declaration suffixes, passing `Cogs`
  into views, primitive calls outside `CogOps`, initial state outside
  mechanisms, writable source visibility, and multi-read graph helpers.
- `CogLintBuildToolPlugin` for build-time checks and
  `CogLintCommandPlugin` for `swift package coglint`, both backed by a
  checksummed macOS 14 artifact containing native arm64 and x86_64 binaries.
- Permanent DocC articles generated from the same fixture corpus that tests
  every rule, plus a setup guide for the version-matched plugin package.

### Changed

- Lint distribution uses the separately versioned-but-coupled
  `skeswa/coglint-plugins` repository. Keeping its binary target outside Cog's
  root manifest prevents ordinary library consumers from eagerly downloading
  an unused lint artifact or resolving the linter's source dependencies.
- Cog and Weather sources now dogfood the same linter command gated in CI.

## [0.3.0] - 2026-08-17

Async state can now schedule, stream, enter, and leave the Cog graph through
explicit typed boundaries. Version 0.2.0 was intentionally not published: its
only proposed payload was an arena-core replacement, and M6 measurements kept
the simple core as the shipping default.

### Breaking

- No intentional source-breaking change. Existing `.latest` declarations and
  `Work.run` selectors retain their 0.1.0 spellings and semantics.

### Added

- Ordered one-shot async policies. `.queue` runs every selected request in
  FIFO order, `.exhaustLatest` finishes current work and catches up once with
  the newest selection, and `.merged` overlaps runs and publishes in landing
  order. The `LatestPolicy` and `OrderedPolicy` type split makes stream work
  latest-only at compile time.
- `Work.stream`, which turns each changed element of a selected
  `AsyncSequence` into its own Cog turn. Dependency replacement and state
  release cancel the iterator and reject late elements; natural completion
  preserves the last success, and a current failure retains the last value in
  `CogStatus`.
- `cogs.values(of:buffering:)`, a current-value-first multicast
  `AsyncSequence` for manual, derived, and async values. Each iterator owns an
  independent graph lease and buffer with `.newest(1)`, `.oldest(n)`, and
  `.unbounded` policies.
- `Reader.track`, in key-path and closure forms, for making properties of an
  external `@Observable` model ordinary selector dependencies. It uses
  continuous `Observations` on 26-era runtimes and a documented one-shot
  re-arm shim on older deployment targets.
- A separate pinned benchmark package covering allocations, propagation,
  boundary notices, value-reference layouts, edge layouts, pinned-key scaling,
  swift-state-graph, and raw Observation, with committed threshold files and a
  live allocation witness.
- A Weather dashboard task that consumes Cog values asynchronously and follows
  the selected city without installing another state owner.

### Changed

- The simple class-state runtime remains the consumer default. The arena core
  and shared linked edge pool remain test- and benchmark-selectable research
  implementations after passing the same public behavior suite but missing
  M6's allocation, ARC, and pinned-key targets.
- Keyed value references keep their public descriptor-and-key identity while
  the selected inline representation avoids a per-reference allocation.

## [0.1.0] - 2026-08-17

The first usable release: declarations, one app-wide runtime, turns, the
SwiftUI boundary, mechanisms, declared lifetimes, and a first async slice.

### Added

- `Cog`, `ManualCog`, and their boxes: declarations that name state without
  creating it, with keyed value references from one declaration, `.readOnly`
  projections, per-declaration equality rules, and explicit or `fileID:line`
  labels.
- One app-wide runtime: `Cogs.bootstrapApp(mechanisms:)`, the `\.cogs`
  SwiftUI environment, tracked UI reads, and one-shot `peek`. A second
  production bootstrap traps in every build.
- Turns: `commit` in a compact single-value form and a `Writer` form, with
  nested commits joining, sibling commits staying separate, and commits during
  a flush queueing in FIFO order.
- Lazy pull with dirty flags, versions, and equality gates, so a read settles
  exactly what it needs and an equal write propagates nothing.
- Cycle detection that names the whole descriptor-and-key path and fails fast.
- A bound on cold first-read nesting. A first read of a never-computed chain
  nests, because a cog's dependencies are known only once its selector has run.
  Past 128 nested computations Cog fails with an error naming the innermost
  links, in debug and release alike, instead of exhausting the stack. Warm
  re-settlement is iterative and stays unbounded by graph depth.
- `Mechanism` and `MechanismController`: bootstrap-only registration of
  reactions, watches, tasks, and state-gated `whenever` scopes, with
  duplicate-name rejection and write-back that queues a new turn.
- Declared lifetime: `.app` for sources, `whileObserved` with a grace period
  for derived and async state, and an opt-in `ManualCogLifetime` for ephemeral
  sources.
- Async state: `AsyncCog`, `AsyncCogBox`, total value reads over a declared
  default, the `status` lens, `CogStatus`, `Work`, `.latest`, and
  exact-generation `refresh` returning `CogRefresh`.
- SwiftUI boundary: per-state Observation boundaries created on first UI read,
  notices emitted only when a value actually changes, and UI notices ordered
  before reactions within a turn.
- `CogTesting`: isolated contexts, `TestClock`, debug-only `seed`, the
  synchronous `withBootstrappedApp` fixture, and narrow diagnostic seams.
- Debug history: a bounded log of turns, writes, recomputations, notices, and
  effect runs, with zero cost in release builds.
- DocC documentation and the `swift/Examples/Weather` example app.

[0.4.0]: https://github.com/skeswa/cog/releases/tag/0.4.0
[0.3.0]: https://github.com/skeswa/cog/releases/tag/0.3.0
[0.1.0]: https://github.com/skeswa/cog/releases/tag/0.1.0
