# Cog for Swift: lint tooling

_August 16, 2026_

This document turns the concept recorded in
[issue #318](https://github.com/skeswa/cog/issues/318) — ship a linter with
Cog, as an executable style guide — into a concrete design: what the tool is,
how it reaches an iOS project, and the first five rules. Everything here is a
proposal. Nothing in this document is settled until it survives a `/vette`
review and lands in the core §10 decision record; §7 lists what remains open.
References beginning "core" resolve in
[exploration.md](./exploration.md) and its companions; bare § references
resolve in this document.

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
  zero dependencies and core §9 already promises no required macros; both rule
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

### 3.1 A standalone `coglint`, nested in this repository

`coglint` is a SwiftSyntax `SyntaxVisitor` executable that lints a file set
and prints findings; rules are Swift types over the AST, not configuration.
It is developed in this repository as its own SwiftPM package at
`swift/Lint/`, beside the root package rather than inside it.

This is the shape the repository already committed to. The plan nests
`swift/Benchmarks` as a "separate SwiftPM package" whose first obligation is
to "prove its dependencies cannot enter the shipped root package"
([plan.md](../impl/plan.md), M5), and its Kotlin-headroom section frames the
repo as a multi-platform monorepo: platform code under `swift/` and later
`kotlin/`, path-filtered CI per platform, namespaced mise tasks. The linter
is the second such package, under the same isolation gate:

- **Cog's zero-dependency guarantee holds.** The linter depends on
  swift-syntax and swift-argument-parser, but SwiftPM reads only the root
  manifest of a resolved repository; a nested package's manifest is invisible
  to consumers. Like `swift/Benchmarks`, the `swift/Lint` skeleton lands with
  a check proving its dependencies cannot reach the root `Package.swift`.
- **The `tools/` contract holds.** The linter lives under `swift/`, where
  Swift-flavored tooling belongs; the root `tools/` directory stays
  platform-neutral repository validation.
- **Everything the rules enforce lives here.** The conventions, their
  decision records, the fixture corpus, the rule articles in the docs
  pipeline, and the Weather dogfood target are all in this repository. A
  rule and the convention it enforces change in one revision, checked by one
  CI — which is the whole premise of an executable style guide.

### 3.2 Products and surfaces

The consumer-facing surface is:

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

### 3.3 Distribution: how a nested package reaches consumers

One SwiftPM limitation shapes distribution: a git dependency resolves only at
the repository root, so no consumer can depend on `swift/Lint` by URL. The
nested package is the workspace; the plugin products must reach consumers
through one of two channels, both fed by the same release artifact — a
checksummed `coglint.artifactbundle.zip` built from `swift/Lint` and attached
to a release:

- **Channel A: products on the root manifest.** The root `Package.swift`
  gains the `binaryTarget` and the two plugin declarations. One repository,
  one tag stream, and the manifest still declares zero package dependencies —
  a binary artifact is not a source dependency. The costs: SwiftPM and Xcode
  may fetch the artifact for every Cog consumer, plugin user or not (eager
  artifact fetching needs verification before this channel is chosen), and a
  lint fix can only ship by tagging Cog.
- **Channel B: a distribution-only manifest repo.** A minimal sibling
  repository, SwiftLintPlugins-style, containing nothing but the
  `binaryTarget` checksum and plugin declarations, regenerated by release
  automation in this repository. Consumers who want the plugin depend on it;
  consumers of Cog alone see nothing. The cost is a second repository — but
  a generated artifact of the release process, not a second workspace;
  nothing is developed there.

The proposal leans to channel B, because it preserves the zero-cost resolve
for ordinary Cog consumers and decouples lint releases from library tags.
Channel A must clear two independent bars: verification that artifact
fetching is lazy — only plugin users pay — and acceptance that a lint fix
ships only when Cog tags. Lazy fetching alone does not decide it. Either
way, all source, rules, fixtures, and docs stay here (§7).

### 3.4 Diagnostics link to the reason

A finding is one line in the compiler's grammar, carrying the rule slug and a
stable documentation URL:

```
WeatherCard.swift:186:7: error: [primitives-only-in-ops] `refresh` is a demand
on the graph; call a named op from a `CogOps` extension —
https://skeswa.github.io/cog/lint/primitives-only-in-ops
```

- Each rule has a DocC article — the violation, why the convention exists,
  the conforming rewrite, and the rule's accepted evasions — published
  through the existing `swift-docs.yml` Pages pipeline. The diagnostic is
  the teaching moment; the page is the lesson. This is the same posture as
  Cog's runtime diagnostics (the cycle path, the escaped-writer message):
  explain, don't merely fail. The URL shape shown above is illustrative
  until open question 4 fixes it — DocC static hosting emits
  `/cog/documentation/…` paths unless a redirect layer is added.
- The `github` reporter emits workflow-command annotations so violations
  land on the PR diff; the `sarif` reporter carries the URL as `helpUri`
  for code scanning. Xcode renders the URL as copyable text, terminals and
  CI logs as a link.
- Findings default to `error`. A suppression is written
  `// coglint:disable-next-line <rule>` and is itself lintable — a later
  rule can require a trailing reason.

### 3.5 Fixtures are the spec, the docs, and the tests

Following SwiftLint's harness and this repository's checker pattern
(`tools/check-task-ledger.mjs` and friends, each of which runs its own
fixture suite first): every rule ships triggering examples with expected
positions, non-triggering examples including the deliberate evasions, and the
same examples render into the rule's DocC article. The linter's own test
suite runs before it is allowed to check anything else, because a broken
checker cannot validate anything.

## 4. The first five rules

Every rule is a thin statement over a shared classification layer, which is
also the intended implementation shape:

- **Cog declarations.** A variable is classified by its initializer: a call
  to one of the six declaration types, or a `.readOnly` projection of an
  already-classified name. Classification yields the shape (keyless or box)
  and the kind (source, derived, async, projection). It never chases
  assignments, so the sanctioned debug seed-target re-export
  (mechanisms §6.6) is out of scope by design, not by luck.
- **Views.** A type with a written `View` conformance in the file, or a
  `body` property typed `some View`.
- **Graph receivers.** `cogs` bound by `@Environment(\.cogs)`, the `c`
  parameter of selectors, reactions, and commit closures, and a mechanism's
  controller.

Evasions are documented once, per classifier, not per rule: a typealias, a
factory function, or a cross-file conformance defeats the classifier, and
every rule built on it inherits that documented miss as a non-triggering
fixture.

| Rule                     | Enforces                                                                             | Confidence                   |
| ------------------------ | ------------------------------------------------------------------------------------ | ---------------------------- |
| `cog-declaration-suffix` | declaration names end in `Cog`/`Cogs` by shape (core §3.1; core §10 item 23)         | high                         |
| `no-cogs-in-view-init`   | views never accept, store, or forward `Cogs` (core §3.4; core §10 item 25)           | high                         |
| `primitives-only-in-ops` | primitives are called only inside `CogOps` extensions (core §3.2; conventions)       | high                         |
| `manual-cog-private`     | writable sources are `private` or `fileprivate` (core §4; core §10 "Who may write?") | highest                      |
| `no-cog-repackaging`     | reads bind to domain locals, never projection bundles (core §3.1; conventions)       | heuristic; strong forms only |

### 4.1 `cog-declaration-suffix`

A variable the declaration classifier recognizes must end in singular `Cog`
(keyless: `Cog`, `ManualCog`, `AsyncCog`, `CogProjection`) or plural `Cogs`
(boxes: `CogBox`, `ManualCogBox`, `AsyncCogBox`, `CogBoxProjection`), with
qualifiers before the suffix. A name with the wrong suffix, the wrong
plurality, or a qualifier after the suffix is a violation. A companion rule
for the unwrap convention — the local bound from a read drops the suffix —
is a natural v2 candidate on the same classifier.

### 4.2 `no-cogs-in-view-init`

Inside any type the view classifier recognizes, a stored property or
initializer parameter whose written type is `Cogs` (including optional and
generic-argument positions) is a violation; the fix is
`@Environment(\.cogs) private var cogs`. The same written-type check applies
to `Cogs` parameters on the view's methods. Its misses are the view
classifier's; the index-store upgrade path (§5) would close the cross-file
gap.

### 4.3 `primitives-only-in-ops`

The only sanctioned call site for a primitive is an `extension CogOps` body,
where it is spelled bare — `commit(...)`, `refresh(...)`, no receiver.
Everywhere else, a `.commit(` or `.refresh(` call on a classified graph
receiver is a violation, as is a bare or `self.`-qualified primitive call
inside an `extension Cogs`; the fix is a domain verb in a `CogOps`
extension. Test targets are exempt by configuration, because tests
legitimately drive the graph directly.

This is deliberately broader than a view rule, and needs no view
classification at all. It catches the inline `refresh` in a view action and
the initial write in `App.init` — both of issue #318's primitive-shaped
evidence, where a view-scoped rule provably misses the second because `App`
is not a `View` — plus a `Binding` setter inside an `extension Cogs`
helper. A nested `Writer` commit stays legal for free: it is lexically
inside the op's `extension CogOps` body.

### 4.4 `manual-cog-private`

A declaration the classifier recognizes as `ManualCog` or `ManualCogBox`
must be `private` or `fileprivate`; either spelling satisfies the rule. Any
wider access level — including the implicit `internal` of a bare `let` — is
a violation; the fix is to narrow the source and expose `.readOnly` or a
derived cog. Accepting both spellings keeps the rule semantic rather than
stylistic: at file scope the two are identical, and spelling there already
belongs to the formatter, whose `FileScopedDeclarationPrivacy` pass
rewrites file-scope `fileprivate` to `private` — a linter taking a side
would either fight or duplicate that check. Access modifiers are literal
tokens and the declaration form is unambiguous, so the rule has essentially
no false-positive surface; it is the natural first rule to implement end to
end.

### 4.5 `no-cog-repackaging`

The heuristic rule, scoped to the strong forms of the anti-pattern:

- an `extension Cogs` or `extension CogOps` member that returns a non-`View`,
  non-`Binding` value assembled from two or more graph reads;
- a function or initializer whose body consists solely of `cogs[...]` /
  `c[...]` reads feeding stored properties or a memberwise initializer.

A `Cogs` initializer parameter is not itself a violation: the settled record
sanctions explicit context at non-view composition boundaries such as
isolated test harnesses (core §10, "Production context access?"), so the
rule matches what a body does with its reads, not how the runtime arrived.
Genuinely derived values belong in a derived cog; values merely read
together belong on their own lines in the body that reads them. Because
"merely repackages" is ultimately a judgment, this rule confines itself to
the patterns above and accepts both misses and the occasional flagged
judgment call; its documentation page explains the boundary, and its
severity is a candidate for `warning` rather than `error` (§7).

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
   in core §10 and the platform snapshot, and issue #318 gets the outcome.
2. **Skeleton.** The nested `swift/Lint` package: layout, the CLI over one
   rule (`manual-cog-private`, the smallest correct rule), the fixture
   harness, the isolation check proving its dependencies cannot enter the
   shipped root package (the `swift/Benchmarks` gate, reused), and the
   artifact-bundle release pipeline with checksummed binaries.
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

1. **Distribution channel.** Two independent criteria: verify whether
   SwiftPM and Xcode fetch a root manifest's binary artifact for consumers
   who never apply the plugin, and decide whether tag-coupled lint releases
   are acceptable. Channel A needs both answers favorable; eager fetching
   alone confirms channel B's distribution-only manifest repo (§3.3).
2. **Naming.** `coglint` as the binary and `swift/Lint` as the package
   directory are working names, as is the distribution repo's name if
   channel B wins; the product names in §3.2 follow them.
3. **Severity policy.** Default `error` for the four high-confidence rules
   is proposed; whether `no-cog-repackaging` starts as `warning`, and
   whether suppressions must carry a reason, are open.
4. **Rule-page home.** Rule articles could live in `Cog.docc` beside the
   conventions they enforce, or in a catalog of the `swift/Lint` package;
   either publishes through the existing Pages pipeline, and the stable URL
   shape (`…/cog/lint/<rule>`) should be fixed before the first diagnostic
   ships.
5. **Version coupling.** How a `coglint` release states the Cog versions it
   understands, and whether the plugin should warn on a mismatch. Under
   channel A the coupling is automatic and the question narrows to how a
   lint fix ships between Cog tags.
6. **The next rules.** Issue #318's remaining candidates — the unwrap-naming
   companion, `@Environment(\.cogs)` declared per-view, initial state in
   `operate` (whose `commit` form `primitives-only-in-ops` already catches),
   `fatalError` over `preconditionFailure`, `nonisolated deinit`
   on generic classes, no `@testable import Cog` in scenario tests — are
   queued behind the first five, several of them library-internal rather
   than consumer-facing.
7. **SwiftLint adjunct.** Whether to publish the regex-expressible subset as
   a `custom_rules` config for SwiftLint shops, accepting the drift risk.
8. **Kotlin.** When to record the Android decision; the ergonomic bar is
   known, the timing is not. The monorepo shape helps here too: the Kotlin
   lint module would live under `kotlin/` beside its library, matching the
   plan's platform layout.
