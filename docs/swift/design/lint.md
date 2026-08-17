# Cog for Swift: lint tooling

_August 16, 2026_

This document turns the concept recorded in
[issue #318](https://github.com/skeswa/cog/issues/318) — ship a linter with
Cog, as an executable style guide — into a concrete design: what the tool is,
how it reaches an iOS project, and the first five rules. Everything here is a
proposal. Nothing in this document is settled until it survives a `/vette`
review and lands in the §10 decision record; §7 lists what remains open.

## 1. Why Cog ships a linter

Cog is deliberately minimal, which makes it expressive enough to be misused
expressively. The conventions that keep a Cog codebase healthy — suffix
naming, environment-resolved `Cogs`, named ops over primitives, flat reads —
exist today as prose in the instruction files and as example code. Prose gets
followed when it happens to be in context; a check that fails the build gets
followed always.

The argument is sharpest for coding agents, which will write a large share of
Cog application code. An agent's compliance with a convention is a function of
whether the convention is _checkable_, not whether it is written down.
Issue #318 records the direct evidence: three settled conventions were
violated in this project's own example app — an inline `refresh` in a view, an
initial write in `App.init` one line below a correct mechanism, and reads
repackaged into a projection struct — and each was found by a human reading
the code, not by any tool.

Two scope rules bound what the linter is allowed to claim:

- **Every rule enforces a documented convention.** A rule exists only when the
  convention it enforces is settled and written down, and every diagnostic
  links to the page that explains why. The linter is a delivery channel for
  the design's decisions, not a second place decisions get made.
- **The linter never duplicates the type system.** Anything the compiler
  already rejects — writing through a `.readOnly` projection, `status` on a
  synchronous cog, a runtime reaction registration — stays a compile error
  with a `swift/CompileFail/` fixture. The linter owns only what compiles
  cleanly but reads wrongly.

## 2. The landscape

The vehicle question from issue #318 has a researched answer. The short form:
no existing linter can host Cog's rules, and the delivery pattern that fits is
a standalone SwiftSyntax tool shipped as a prebuilt binary behind SwiftPM
plugins.

### 2.1 Vehicles that do not fit

- **SwiftLint.** There is no native custom-rule channel. The plugin-system
  RFC ([realm/SwiftLint#2529](https://github.com/realm/SwiftLint/issues/2529))
  closed unimplemented; the only way to ship compiled rules is building a
  custom SwiftLint with Bazel (`swiftlint_extra_rules`), which is unshippable
  to consumers. Config-file `custom_rules` remain regex-only: they could
  carry the naming-suffix rule, but not "a `View` stores `Cogs`", not access
  levels, and not repackaging — and they cannot autocorrect. Riding SwiftLint
  would also bind every Cog user to a tool this project deliberately does not
  use ([plan.md](../impl/plan.md): toolchain `swift format` only, no
  SwiftLint).
- **swift-format.** Rules are compiled in; there is no third-party rule
  mechanism and no open proposal for one. Adding a rule means upstreaming or
  forking.
- **Macros.** Macro-emitted diagnostics are a real, shipped enforcement
  pattern (TCA's `@Reducer` fails misuse at compile time with fix-its), but a
  macro sees only the declaration it is attached to — it can never police the
  code that avoids it, which is where anti-patterns live — and a macro drags
  swift-syntax into every consumer's dependency resolution. Cog resolves with
  zero dependencies and §9 already promises no required macros; both rule
  macros out as the linter's vehicle. They remain available later as a
  complementary channel at declaration sites Cog owns.
- **Type-aware backends.** SwiftLint's `analyze` mode is driven by a full
  clean-build compiler log and has broken across four consecutive Xcode
  releases; sourcekitd queries need full compiler arguments and pay
  type-checking cost per request. Neither is a foundation. The credible
  type-aware path — an IndexStoreDB sidecar over the build's index store, as
  Periphery uses — is real but requires a prior build, so it is an upgrade
  path (§5), not the v1 core.

### 2.2 The pattern that fits

[SwiftLintPlugins](https://github.com/SimplyDanny/SwiftLintPlugins) and
[airbnb/swift](https://github.com/airbnb/swift) demonstrate the working shape
for first-party tooling:

- a standalone executable released as a checksummed
  `.artifactbundle.zip` and referenced as a SwiftPM `binaryTarget`, so
  consumers download a prebuilt binary and never compile the linter or
  swift-syntax;
- a `.buildTool()` plugin that runs it on every build, surfacing findings in
  Xcode. [SE-0303](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0303-swiftpm-extensible-build-tools.md)
  makes the binary form structurally required, not merely polite: a
  `prebuildCommand` may only invoke binary-target tools;
- a `.command()` plugin (`swift package coglint`) for on-demand and CI runs,
  with `.writeToPackageDirectory` reserved for a future `--fix`;
- the bare CLI for run-script phases, pre-commit hooks, and non-SPM setups.

Diagnostics reach the Xcode issue navigator and inline editor annotations by
printing the classic `path:line:col: warning: message` form, which Xcode
parses from plugin output exactly as it parses run-script output. One known
platform caveat: since Xcode 16.3 a scheme-interaction bug sometimes demotes
plugin warnings to the report navigator only
([realm/SwiftLint#6041](https://github.com/realm/SwiftLint/issues/6041), still
reproducing on Xcode 26.2).

Notably, research found no library that ships its own SwiftSyntax usage
checker as an SPM plugin today. The pieces are each proven — SwiftLintPlugins
proves the packaging, [swift-ast-lint](https://github.com/Ryu0118/swift-ast-lint)
proves the small-bespoke-linter economics — but Cog would be assembling a
pattern, not copying one.

### 2.3 Syntax-only analysis is enough to start

The industry posture is settled: 243 of SwiftLint's 251 rules run on pure
SwiftSyntax, matching written spellings precisely and accepting documented
false negatives wherever type identity would be needed. Cog is unusually well
suited to that posture, by design rather than luck:

- every declaration is a top-level or type-scoped `let` whose initializer
  names one of six public types — `Cog`, `CogBox`, `ManualCog`,
  `ManualCogBox`, `AsyncCog`, `AsyncCogBox` — or projects one with
  `.readOnly`; there are no property wrappers, macros, or factory functions
  to see through;
- the settled read spelling flows every graph interaction through two
  conventional receivers, `cogs` and `c`, so call-shape matching on those
  names has the precision SwiftLint's name-matching rules rely on;
- the conventions themselves are spelled in tokens a visitor can read:
  suffixes, access modifiers, written parameter types, `@Environment(\.cogs)`.

The accepted trade: code that hides cog-ness behind a typealias, a factory
function, or a cross-file conformance evades a rule. Each rule documents its
evasions as non-triggering fixture examples, and the posture is recorded
openly: the linter is precise on the convention-conforming spelling and
silent on determined evasion, which in practice is a reviewer's problem, not
a linter's.

### 2.4 The bar on Android

Jetpack Compose ships its lint rules _inside the library artifact_: the
`lintPublish` configuration packages them as `lint.jar` in the AAR, so adding
the dependency gives every consumer editor-time enforcement with zero setup.
That is the ergonomic bar, and the Kotlin sibling should plan a lint module
from day one — but per the platform-separation rule, that is a Kotlin
decision to be recorded in the Kotlin docs, not here. Swift has no
`lintPublish` equivalent; the plugin one-liner per target is the closest
available automaticity.

## 3. Proposed architecture

### 3.1 A standalone `coglint`, in its own package

`coglint` is a SwiftSyntax `SyntaxVisitor` executable that lints a file set
and prints findings; rules are Swift types over the AST, not configuration.
It lives in its own repository (working name `skeswa/cog-lint`), for three
reasons that are each sufficient:

- **Cog's zero-dependency guarantee.** The linter depends on swift-syntax
  and swift-argument-parser. SwiftPM resolves a package at its repository
  root, so the only way to keep those out of `cog`'s resolution graph
  entirely is a separate repository.
- **The `tools/` contract.** [plan.md](../impl/plan.md) reserves the root
  `tools/` directory for platform-neutral repository validation; a Swift
  linter is the first thing that would violate that, and should not.
- **Release cadence.** The linter recognizes Cog's public API names, which
  are frozen for 0.1.0 but will move; a separate package versions the
  coupling explicitly instead of entangling the library's tags.

### 3.2 Products and surfaces

The `cog-lint` package exposes:

| Product                | Surface                                                                                           |
| ---------------------- | ------------------------------------------------------------------------------------------------- |
| `coglint` (CLI)        | `coglint [paths] [--reporter xcode\|github\|sarif]`; run-script phases, pre-commit, mise, CI      |
| `CogLintPlugin`        | build-tool plugin: prebuild command over the binary target; findings on every Xcode/SwiftPM build |
| `CogLintCommandPlugin` | `swift package coglint`; on-demand runs, CI, and the future `--fix` home                          |
| binary target          | `coglint.artifactbundle.zip` per release, checksummed; consumers never build the linter           |

Consumer wiring is one `plugins:` line per app target for SwiftPM and Xcode
targets alike (Xcode 14+ supports build-tool plugins on xcodeproj targets),
with the CLI as the fallback for older setups. The prebuild command caches in
`pluginWorkDirectory` so unchanged files re-lint cheaply, following the
SwiftLint plugin's pattern.

In this repository, a `mise run lint:swift` task runs the same binary over
`swift/` and the Weather example, and CI runs it in the existing checks lane.
The Weather app is the standing dogfood target — the code that produced
issue #318's evidence becomes the code that proves the rules fire.

### 3.3 Diagnostics link to the reason

A finding is one line in the compiler's grammar, carrying the rule slug and a
stable documentation URL:

```
WeatherCard.swift:186:7: error: [no-primitives-in-views] a view asks the graph
through a named op, never `refresh` inline — https://skeswa.github.io/cog/lint/no-primitives-in-views
```

- Each rule has a DocC article — the violation, why the convention exists,
  the conforming rewrite, and the rule's accepted evasions — published
  through the existing `swift-docs.yml` Pages pipeline. The diagnostic is
  the teaching moment; the page is the lesson. This is the same posture as
  Cog's runtime diagnostics (the cycle path, the escaped-writer message):
  explain, don't merely fail.
- The `github` reporter emits workflow-command annotations so violations
  land on the PR diff; the `sarif` reporter carries the URL as `helpUri`
  for code scanning. Xcode renders the URL as copyable text, terminals and
  CI logs as a link.
- Findings default to `error`. A suppression is written
  `// coglint:disable-next-line <rule>` and is itself lintable — a later
  rule can require a trailing reason.

### 3.4 Fixtures are the spec, the docs, and the tests

Following SwiftLint's harness and this repository's checker pattern
(`tools/check-task-ledger.mjs` and friends, each of which runs its own
fixture suite first): every rule ships triggering examples with expected
positions, non-triggering examples including the deliberate evasions, and the
same examples render into the rule's DocC article. The linter's own test
suite runs before it is allowed to check anything else, because a broken
checker cannot validate anything.

## 4. The first five rules

| Rule                     | Enforces                                                                  | Confidence                   |
| ------------------------ | ------------------------------------------------------------------------- | ---------------------------- |
| `cog-declaration-suffix` | declaration names end in `Cog`/`Cogs` by shape (§3.1; §10 item 23)        | high                         |
| `no-cogs-in-view-init`   | views never accept, store, or forward `Cogs` (§3.4; §10 item 25)          | high                         |
| `no-primitives-in-views` | views call named ops, never `commit`/`refresh` inline (§3.2; conventions) | high                         |
| `manual-cog-fileprivate` | writable sources are `fileprivate`/`private` (§4; §10 "Who may write?")   | highest                      |
| `no-cog-repackaging`     | reads bind to domain locals, never projection bundles (§3.1; conventions) | heuristic; strong forms only |

### 4.1 `cog-declaration-suffix`

A variable whose initializer calls one of the six declaration types, or
projects one with `.readOnly`, must end in singular `Cog` (keyless: `Cog`,
`ManualCog`, `AsyncCog`, `CogProjection`) or plural `Cogs` (boxes: `CogBox`,
`ManualCogBox`, `AsyncCogBox`, `CogBoxProjection`), with qualifiers before
the suffix. The rule reads the initializer expression and any written type
annotation; a name with the wrong suffix, the wrong plurality, or a qualifier
after the suffix is a violation. Accepted evasions: values returned from
factory functions and inferred generic returns. A companion rule for the
unwrap convention — the local bound from a read drops the suffix — is a
natural v2 candidate once this rule's classification machinery exists.

### 4.2 `no-cogs-in-view-init`

Inside any type the linter classifies as a view — a written `View`
conformance in the file, or a `body` property typed `some View` — a stored
property or initializer parameter whose written type is `Cogs` (including
optional and generic-argument positions) is a violation; the fix is
`@Environment(\.cogs) private var cogs`. The same written-type check applies
to `Cogs` parameters on the view's methods. Accepted evasions: conformance
declared in another file and typealiased spellings; the index-store upgrade
path (§5) would close the cross-file gap.

### 4.3 `no-primitives-in-views`

Inside a classified view, a call to `.commit(` or `.refresh(` whose receiver
is `cogs` — or any receiver the environment declaration in that view binds —
is a violation; the fix is a domain verb in a `CogOps` extension. The
receiver-name restriction is what keeps precision high: some unrelated type's
`commit` on another receiver does not trigger. The rule deliberately covers
`refresh` with the same weight as `commit`; the settled convention treats
both as demands on the graph, and the missed inline `refresh` in the Weather
app is this rule's founding counterexample.

### 4.4 `manual-cog-fileprivate`

A declaration initialized with `ManualCog` or `ManualCogBox` must be
`fileprivate` at file scope or `private` inside a type. Any other access
level — including the implicit `internal` of a bare `let` — is a violation;
the fix is to mark the source `fileprivate` and expose `.readOnly` or a
derived cog. Access modifiers are literal tokens and the declaration form is
unambiguous, so this rule has essentially no false-positive surface; it is
the natural first rule to implement end to end.

### 4.5 `no-cog-repackaging`

The heuristic rule, scoped to the strong forms of the anti-pattern:

- a non-`View` type with an initializer parameter of written type `Cogs`;
- an `extension Cogs` or `extension CogOps` member that returns a non-`View`,
  non-`Binding` value assembled from two or more graph reads;
- a function or initializer whose body consists solely of `cogs[...]` /
  `c[...]` reads feeding a memberwise initializer.

Genuinely derived values belong in a derived cog; values merely read together
belong on their own lines in the body that reads them. Because "merely
repackages" is ultimately a judgment, this rule confines itself to the
patterns above and accepts both misses and the occasional flagged judgment
call; its documentation page explains the boundary, and its severity is a
candidate for `warning` rather than `error` (§7).

## 5. Non-goals for v1

- **No type information.** V1 is pure SwiftSyntax. If the accepted evasions
  prove costly in practice, the recorded upgrade path is an opt-in
  IndexStoreDB mode over the build's index store (Periphery's approach),
  which can resolve cross-file `View` conformance and true type identity at
  the price of requiring a prior build. That mode is a measured decision for
  later, not a v1 promise.
- **No autocorrect.** `--fix` waits until rules and fixtures are stable;
  fix-its change a rule's contract and deserve their own fixtures.
- **No general style.** Formatting and ordinary Swift style remain
  `swift format`'s business; the linter checks only Cog usage.
- **No duplication of compile-time enforcement.** Everything
  `swift/CompileFail/` proves stays there.
- **No SwiftLint adjunct config.** Publishing a regex `custom_rules` subset
  for teams already on SwiftLint is cheap but creates a second,
  weaker-and-drifting rule surface; deferred unless demand appears (§7).

## 6. Rollout

Phased, with the same discipline as the main plan — each phase lands green
and the design is not implementation until it is accepted:

1. **Vette.** This document goes through `/vette`; accepted decisions land
   in §10 and the platform snapshot, and issue #318 gets the outcome.
2. **Skeleton.** The `cog-lint` repository: package layout, the CLI over one
   rule (`manual-cog-fileprivate`, the smallest correct rule), the fixture
   harness, and the artifact-bundle release pipeline with checksummed
   binaries.
3. **The five rules.** Remaining rules land one at a time, fixtures first,
   each with its DocC article and stable URL.
4. **Surfaces.** The build-tool and command plugins, the reporters, the
   `mise run lint:swift` task here, and the CI job that lints `swift/` and
   the Weather app.
5. **Integration.** Only after acceptance: the plan-to-task contract means
   linter work enters [plan.md](../impl/plan.md) and the task ledger in the
   same change, with `mise run tasks:check` green.

Kotlin parity is deliberately outside this rollout; the Compose `lintPublish`
finding (§2.4) seeds a future Kotlin design document.

## 7. Open questions

1. **Naming.** `coglint` as the binary and `cog-lint` as the repository are
   working names; the product names in §3.2 follow them.
2. **Severity policy.** Default `error` for the four high-confidence rules
   is proposed; whether `no-cog-repackaging` starts as `warning`, and
   whether suppressions must carry a reason, are open.
3. **Rule-page home.** Rule articles could live in `Cog.docc` beside the
   conventions they enforce, or in the lint repository's own catalog; the
   stable URL shape (`…/cog/lint/<rule>`) should be fixed before the first
   diagnostic ships.
4. **Version coupling.** How a `coglint` release states the Cog versions it
   understands, and whether the plugin should warn on a mismatch.
5. **The next rules.** Issue #318's remaining candidates — the unwrap-naming
   companion, `@Environment(\.cogs)` declared per-view, initial state in
   `operate`, `fatalError` over `preconditionFailure`, `nonisolated deinit`
   on generic classes, no `@testable import Cog` in scenario tests — are
   queued behind the first five, several of them library-internal rather
   than consumer-facing.
6. **SwiftLint adjunct.** Whether to publish the regex-expressible subset as
   a `custom_rules` config for SwiftLint shops, accepting the drift risk.
7. **Kotlin.** When to record the Android decision; the ergonomic bar is
   known, the timing is not.
