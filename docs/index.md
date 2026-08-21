---
layout: home
# The site title is already "Cog"; the template would render "Cog · Cog".
titleTemplate: false

hero:
  name: Cog
  text: Fine-grained state for native mobile UI
  tagline: One authoritative graph per app. Every read correct, every update minimal — in SwiftUI today and Jetpack Compose next.
  actions:
    - theme: brand
      text: Swift design
      link: /swift/
    - theme: alt
      text: API reference
      link: /documentation/cog/
    - theme: alt
      text: View on GitHub
      link: https://github.com/skeswa/cog

features:
  - title: Cog should feel simple
    details: Declaring, reading, and changing state looks like normal Swift or Kotlin. Runtime complexity stays behind the API.
  - title: Every state read is correct
    details: A read matches the latest committed source state after settling every dependency it needs — never a torn update, stale derived value, or half-finished change.
  - title: Overhead is measured, not asserted
    details: Needless recomputation, allocation, and UI updates are treated as defects, and competing implementations are benchmarked rather than argued about.
  - title: State is singular
    details: One running app has one authoritative graph, and each mutable fact has exactly one writable source in it. No state islands, no mirrored sources.
---

## Where to start

Cog is two platform-native libraries that share four principles but not an API.
The Swift library is real and usable through 0.4.0; the Kotlin library has a
complete first design and no implementation yet.

- **[Cog for Swift](./swift/)** — the reading order, current decisions, open
  questions, and implementation record for SwiftUI. Start here if you want to
  use Cog today.
- **[Cog for Kotlin](./kotlin/)** — the Compose snapshot architecture, a worked
  feature, Flow and effects guidance, and the Android benchmark plan.
- **[API reference](/documentation/cog/)** — the generated DocC documentation
  for the shipping Swift library, including
  [Getting Started](/documentation/cog/gettingstarted) and
  [Linting your app](/documentation/cog/lintingyourapp).

## Working on Cog

- **[CI and runner operations](./maintainers/ci.md)** — the self-hosted
  boundary, the hosted fork lane, and the workflow hardening contract.
- **[Releasing Cog for Swift](./maintainers/releasing.md)** — candidate,
  annotated tag, publication, and post-release verification.
- **[Dart and Flutter snapshot](./dump-2026-08-06.md)** — frozen historical
  context. It is not normative for either current library.
