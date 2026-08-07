# Cog

Cog is a fine-grained state-management project for native mobile UI. It is
planned as two platform-native libraries:

- **iOS:** a Swift library for SwiftUI, using `@Observable` at the UI boundary
  and its own MainActor-confined dependency graph inside.
- **Android:** a Kotlin library for Jetpack Compose, built first over the
  Compose snapshot runtime with its own store, turn, lifetime, and async rules.

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

Correctness is not traded for speed. Performance work should also keep the
common API simple.

## Status

Cog is in the design phase. The Swift and Android designs are detailed enough
to begin their correctness and performance spikes. Neither library is
implemented yet.

The earlier Dart and Flutter experiment has been removed from the current
tree. It remains available in Git history.

## Documentation

- **[Swift design](./docs/swift/README.md):** the reading order, current
  decisions, open questions, and implementation plan for SwiftUI.
- **[Kotlin design](./docs/kotlin/README.md):** the reading order, Compose
  snapshot architecture, Flow and effects guidance, and Android benchmark
  plan.
- **[Dart and Flutter design snapshot](./docs/dump-2026-08-06.md):** frozen
  historical context. It is not normative for either current library.
