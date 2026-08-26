# Cog for Swift: handbook

_August 26, 2026_

This is the working handbook for building an app on Cog: the conventions the
project has settled on, distilled from the design documents and proven in the
three worked example apps. Each chapter states its rules first, then shows the
rule in real code.

The handbook is operational, not normative. The
[core design](../design/exploration.md) and
[mechanisms](../design/mechanisms.md) documents define what Cog _is_ and
record why each decision went the way it did; this guide tells you what to
_write_. Where the two ever disagree, the design documents win — and the
disagreement is a bug in this guide.

Every convention here is exercised by at least one of the example apps, which
are the handbook's companion code:

- [Weather](https://github.com/skeswa/cog/tree/main/swift/Examples/Weather) —
  async state, mechanisms, and exported values.
- [TodoMVC](https://github.com/skeswa/cog/tree/main/swift/Examples/TodoMVC) —
  keyed row state, dynamic filters, atomic list actions, and persistence.
- [Trails](https://github.com/skeswa/cog/tree/main/swift/Examples/Trails) —
  state-driven navigation, deep linking, and restoration.

## The chapters

1. **[Structuring an app](./app-structure.md)** — one app-wide runtime, how it
   reaches SwiftUI, and the `…State+Aspect.swift` file families that organize
   a state layer.
2. **[Declaring state](./declaring-state.md)** — naming by shape, the
   underscore-and-projection pattern, and choosing among manual, automatic,
   async, and keyed declarations.
3. **[Reading state](./reading-state.md)** — unwrapping reads into domain
   locals, reading flatly, and the status lens.
4. **[Writing state](./writing-state.md)** — named operations, atomic turns,
   and composing cross-file writes through nested turns.
5. **[SwiftUI integration](./swiftui.md)** — environment resolution, binding
   adapters, and what stays view-local.
6. **[Side effects](./side-effects.md)** — mechanisms, initial state, gated
   scopes, and the persistence pattern.
7. **[Navigation and deep linking](./navigation.md)** — driving tabs, stacks,
   sheets, URLs, and restoration from ordinary graph state.
8. **[Testing](./testing.md)** — isolated runtimes, seeding, injected clocks,
   and proving behavior headlessly.

## The four rules behind every convention

Each convention in this handbook exists to preserve the project's four
principles, so when a situation the handbook does not cover comes up, decide
by them:

1. Cog should feel simple to use, read, and reason about.
2. Every state read should be correct.
3. Cog should minimize runtime overhead without weakening the other rules.
4. Cog state should be singular: one running app has one authoritative graph,
   each mutable fact has one writable source in it, and screens or features do
   not create state islands or mirror sources.

Several of the conventions are enforced mechanically by
[`coglint`](../design/lint.md); the handbook notes where a rule has a linter
behind it.
