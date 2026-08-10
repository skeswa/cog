# CLAUDE.md

This file guides Claude Code when working in this repository. `AGENTS.md`
mirrors it for other coding agents; keep the two files in sync.

## What this is

The design workspace for **Cog**, a fine-grained state-management project for
native mobile UI. Cog is planned as:

- a Swift library for SwiftUI on iOS, built over `@Observable` at the boundary
  with one app-wide MainActor-confined dependency graph inside; and
- a Kotlin library for Jetpack Compose on Android with one app-wide graph.

The Swift and Kotlin designs exist, but there is no implementation and there
are no build or test commands. Tooling is versioned with mise (`mise.toml`):
`mise run fmt` formats the repo with Oxfmt, and `mise run fmt:check`
verifies formatting without writing. `.oxfmtrc.json` excludes the frozen
`docs/dump-2026-08-06.md` from formatting. The next phase for each platform
is the spike in its `exploration.md` §11, as amended by its `perf.md` §9. For
Swift, `docs/swift/plan.md` turns that spike into milestones with package
layout, tooling, CI, and release steps.

## Layout

- `README.md` — project overview, shared principles, platform status, and
  documentation entry points.
- `docs/dump-2026-08-06.md` — frozen snapshot of the old Dart and Flutter
  design. Historical background only; never normative and never edited.
- `docs/swift/` — living Swift design documents. Start with `README.md`.
  `exploration.md` covers the core architecture and API; `effects.md` covers
  effects and background work; `rx.md` maps Rx concepts; `perf.md` covers the
  data-oriented implementation and benchmark plan; `plan.md` is the
  implementation plan with milestones, tooling, CI, and release process.
- `docs/kotlin/` — living Kotlin and Jetpack Compose design documents. Start
  with `README.md`. `exploration.md` covers the core architecture and API;
  `example.md` gives a full worked feature; `effects.md` covers effects and
  background work; `flows.md` maps Flow and reactive concepts; `perf.md`
  covers the runtime candidates and benchmark plan.

## Project principles

Every design and implementation choice should preserve four rules:

1. Cog should feel simple to use, read, and reason about.
2. Every state read should be correct.
3. Cog should minimize runtime overhead without weakening the other rules.
4. Cog state should be singular: one running app has one authoritative graph,
   each mutable fact represented in Cog has one writable source in it, and
   screens or features do not create state islands or mirror sources.

For Swift, a correct normal read uses the latest completed turn and settles
every dependency needed for that value. A `Writer` read during a commit sees
that turn's staged source values. Async uncertainty stays explicit in
`CogPhase`. Production uses one app-wide `Cogtext`.

For Kotlin, a correct normal read also uses the latest completed turn and
settles every dependency it needs. A writer read sees its turn's staged source
values. A grouped read and a Compose read see one consistent snapshot. Async
uncertainty stays explicit in `CogPhase`.

Kotlin production uses one process-wide `CogStore`. Screens and
ViewModels use that singleton and never create or close it.

Tests and previews are separate app runtimes. Each may create one isolated
`Cogtext` or `CogStore`, but must not fragment state inside
that runtime.

## Conventions

- **Keep platform designs separate.** Shared principles apply to both
  libraries, but Swift decisions are normative only for Swift. Do not assume
  an API or implementation choice also applies to Android without recording an
  Android decision.
- **Preserve shared Swift section numbering.** The companion docs were split
  from `exploration.md`: `effects.md` is §6 and `rx.md` is §5.4. A reference
  such as “§6.4” resolves in `effects.md`. Do not renumber these sections.
- **Preserve shared Kotlin section numbering.** The Kotlin companion docs use
  the same map: `effects.md` is §6 and `flows.md` is §5.4.
- **Dated files are frozen; undated files are living.** Living design docs use
  short lowercase names and carry an authorship date below the title.
- **Map new docs.** Add new Swift docs to `docs/swift/README.md`. Add new
  platform doc sets to the root `README.md`.
- **Do not re-litigate settled decisions.** The Swift snapshot is in
  `docs/swift/README.md` under “Where things stand.” The full settled/open
  ledger is `docs/swift/exploration.md` §10. The Kotlin snapshot and ledger are
  in `docs/kotlin/README.md` and `docs/kotlin/exploration.md` §10. Designs are
  hardened through `/vette` reviews. When the user accepts a decision from a
  review, update both records for that platform. Track real open questions in
  §10.
- **Keep performance claims benchmark-gated.** Both `perf.md` documents defer
  representation choices to benchmarks. Do not mark them settled without
  measurements.
- **Keep root instructions synchronized.** Any guidance change in `AGENTS.md`
  must also be made in `CLAUDE.md`, and vice versa.
