# AGENTS.md

This file guides coding agents working in this repository. `CLAUDE.md` mirrors
it for Claude Code; keep the two files in sync.

## What this is

The design workspace for **Cog**, a fine-grained state-management project for
native mobile UI. Cog is planned as:

- a Swift library for SwiftUI on iOS, built over `@Observable` at the boundary
  with its own MainActor-confined dependency graph inside; and
- a Kotlin library for Jetpack Compose on Android.

Only the Swift design exists today. There is no implementation and there are
no build, lint, or test commands. The next Swift phase is the spike in
`docs/swift/exploration.md` §11, as amended by `docs/swift/perf.md` §9.

## Layout

- `README.md` — project overview, shared principles, platform status, and
  documentation entry points.
- `docs/dump-2026-08-06.md` — frozen snapshot of the old Dart and Flutter
  design. Historical background only; never normative and never edited.
- `docs/swift/` — living Swift design documents. Start with `README.md`.
  `exploration.md` covers the core architecture and API; `effects.md` covers
  effects and background work; `rx.md` maps Rx concepts; `perf.md` covers the
  data-oriented implementation and benchmark plan.
- Android design documents do not exist yet. When that work begins, give it a
  sibling directory under `docs/` with its own `README.md`, then link it from
  the root README.

## Project principles

Every design and implementation choice should preserve three rules:

1. Cog should feel simple to use, read, and reason about.
2. Every state read should be correct.
3. Cog should minimize runtime overhead without weakening the first two rules.

For Swift, a correct normal read uses the latest completed turn and settles
every dependency needed for that value. A `Writer` read during a commit sees
that turn's staged source values. Async uncertainty stays explicit in
`CogPhase`.

## Conventions

- **Keep platform designs separate.** Shared principles apply to both
  libraries, but Swift decisions are normative only for Swift. Do not assume
  an API or implementation choice also applies to Android without recording an
  Android decision.
- **Preserve shared Swift section numbering.** The companion docs were split
  from `exploration.md`: `effects.md` is §6 and `rx.md` is §5.4. A reference
  such as “§6.4” resolves in `effects.md`. Do not renumber these sections.
- **Dated files are frozen; undated files are living.** Living design docs use
  short lowercase names and carry an authorship date below the title.
- **Map new docs.** Add new Swift docs to `docs/swift/README.md`. Add new
  platform doc sets to the root `README.md`.
- **Do not re-litigate settled decisions.** The Swift snapshot is in
  `docs/swift/README.md` under “Where things stand.” The full settled/open
  ledger is `docs/swift/exploration.md` §10. Designs are hardened through
  `/vette` reviews. When the user accepts a decision from a review, update both
  records. Track real open questions in §10.
- **Keep performance claims benchmark-gated.** `docs/swift/perf.md` defers ref
  layout, edge layout, hash tables, and exclusivity attributes to benchmarks.
  Do not mark them settled without measurements.
- **Keep root instructions synchronized.** Any guidance change in `AGENTS.md`
  must also be made in `CLAUDE.md`, and vice versa.
