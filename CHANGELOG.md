# Changelog

All notable changes to Cog for Swift are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Cog is in 0.x. A **minor** release may break source compatibility and says so
under a "Breaking" heading; a **patch** release only adds or fixes. Pin
accordingly:

```swift
.package(url: "https://github.com/skeswa/cog.git", .upToNextMinor(from: "0.1.0"))
```

Kotlin releases through Maven coordinates and is not versioned here.

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

[0.1.0]: https://github.com/skeswa/cog/releases/tag/0.1.0
