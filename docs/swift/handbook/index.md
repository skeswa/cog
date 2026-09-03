---
description: "The working conventions for building an app on Cog, each proven in the example apps."
---

# Cog for Swift: handbook

This handbook shows you how to build an app on Cog. It collects the
conventions the project has settled on. Each chapter states its rules first,
then shows the rules in real code.

The handbook tells you what to write. It does not explain why Cog works the
way it does — the [core design](../design/exploration.md) and
[mechanisms](../design/mechanisms.md) documents do that, and they also record
why each decision went the way it did. If this handbook ever disagrees with
them, the design documents win, and the disagreement is a bug in the
handbook.

Every convention here is used by at least one of the example apps. They are
the handbook's companion code:

- [Weather](https://github.com/skeswa/cog/tree/main/swift/Examples/Weather) —
  async state, mechanisms, and exported values.
- [TodoMVC](https://github.com/skeswa/cog/tree/main/swift/Examples/TodoMVC) —
  keyed row state, dynamic filters, atomic list actions, and persistence.
- [Trails](https://github.com/skeswa/cog/tree/main/swift/Examples/Trails) —
  state-driven navigation, deep linking, and restoration.

## The chapters

1. **[Structuring an app](./app-structure.md)** — one app-wide runtime, how
   views reach it, and the `…Rig+Aspect.swift` files that organize a state
   layer.
2. **[Declaring state](./declaring-state.md)** — how to name state, the
   underscore-and-projection pattern, and how to choose among manual,
   automatic, async, and keyed declarations.
3. **[Reading state](./reading-state.md)** — how to unwrap reads into plain
   locals, why reads stay flat, and how to read async status.
4. **[Writing state](./writing-state.md)** — named operations, atomic turns,
   and how writes in different files combine into one turn.
5. **[SwiftUI integration](./swiftui.md)** — how views find the runtime, how
   bindings work, and what stays in the view.
6. **[Side effects](./side-effects.md)** — mechanisms, initial state, gated
   scopes, and the persistence pattern.
7. **[Navigation and deep linking](./navigation.md)** — driving tabs, stacks,
   sheets, URLs, and restoration from ordinary graph state.
8. **[Testing](./testing.md)** — isolated runtimes, seeding, injected clocks,
   and proving behavior without a UI.

## The four rules behind every convention

Every convention in this handbook exists to protect the project's four
principles. When you hit a case the handbook does not cover, decide by them:

1. Cog should feel simple to use, read, and reason about.
2. Every state read should be correct.
3. Cog should minimize runtime overhead without weakening the other rules.
4. Cog state should be singular: one running app has one authoritative graph,
   each mutable fact has one writable source in it, and screens or features do
   not create state islands or mirror sources.

Some of the conventions are checked by a linter,
[`coglint`](../design/lint.md). The handbook notes where a rule has a linter
behind it.
