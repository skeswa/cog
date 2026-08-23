# Cog for Swift: lint tooling

_August 17, 2026_

Cog ships `coglint`, a SwiftSyntax linter for Cog usage rules. It is an
executable style guide: each rule enforces a written convention, and each
error links to the matching DocC page.

References that start with “core” point to
[core design](./exploration.md) and its companion files. Other section links
point into this file.

## 1. Why Cog ships a linter

Cog's API is small, but code can still use it in hard-to-read ways. Examples
include calling `refresh` inside a view, setting initial state in `App.init`, or
hiding several reads in a helper object. These patterns compile. A linter can
catch them during every build.

Two rules limit the linter's scope:

- It enforces only settled, written Cog conventions. The design stays the
  source of truth.
- It does not repeat compiler checks. Compile errors stay in
  `swift/CompileFail/`; the linter checks valid Swift that breaks Cog style.

## 2. Why this tool shape fits

`coglint` is a standalone SwiftSyntax executable. Consumers download a native
binary and run it through SwiftPM plugins, a script, or the command line.

Other choices do not fit:

- SwiftLint has no native third-party rule system. Its custom rules use regex.
- `swift format` has no third-party rules.
- A macro sees only code attached to that macro. It also adds swift-syntax to a
  consumer's dependency graph.
- SourceKit and IndexStoreDB can add type data, but they need compiler settings
  or a finished build. They remain possible upgrades, not v1 needs.

SwiftPM build-tool plugins require a binary tool for a prebuild command. The
plugin runs the binary on each build and prints normal
`path:line:column: error:` messages for Xcode. A command plugin supports
on-demand and CI use.

### 2.1 Syntax-only analysis

Syntax is enough for the first rules because Cog code has clear written forms:

- declarations name `Cog`, `CogBox`, their nested `Manual`, `Async`, or
  `Projection` shapes, or use `.readOnly`;
- graph reads use the usual `cogs` or `c` receiver; and
- views write `View`, `some View`, and `@Environment(\.cogs)` in source.

A typealias, factory, or conformance declared in another file can hide this
evidence. The linter reports only syntax it can identify with high confidence.
Each rule fixture shows these accepted misses.

Android has a better delivery path: a Compose library can place lint rules in
its AAR with `lintPublish`. Kotlin should use that platform feature instead of
copying this Swift package design.

## 3. Architecture

### 3.1 Development package and products

The source lives in the separate `swift/Lint` SwiftPM package. Its swift-syntax
and swift-argument-parser dependencies cannot enter Cog's root package graph.

| Product                  | Use                                                     |
| ------------------------ | ------------------------------------------------------- |
| `coglint`                | CLI for scripts, hooks, mise, and CI                    |
| `CogLintBuildToolPlugin` | Runs the linter during SwiftPM and Xcode builds         |
| `CogLintCommandPlugin`   | Provides `swift package coglint`                        |
| `CogLintBinary`          | Native executable in `CogLintBinary.artifactbundle.zip` |

The CLI supports Xcode, GitHub, and SARIF reporters. The build plugin uses its
work directory as a cache so unchanged files are cheap to check.

In this repo, `mise run lint:swift` lints library, Storefront, example, and test
sources with the correct target role. The Weather app is the main dogfood app.

### 3.2 Distribution and releases

SwiftPM cannot resolve the nested `swift/Lint` package from a Git URL. The
generated sibling repo, `skeswa/coglint-plugins`, therefore publishes the
`CogLintPlugins` package. Only users who add that package fetch the binary.
Normal Cog users keep a source-only, dependency-free root package.

Cog and `coglint` use the same version. Source, tests, fixtures, and DocC pages
stay in this repo. The sibling manifest points to the matching immutable Cog
release asset and checksum. It has no independent version line.

The Actions-only release order is:

1. Build and test both native `coglint` variants from the exact Cog release
   candidate.
2. Publish the Cog tag, release, binary archive, checksum, provenance, and docs.
3. Generate and publish the sibling package at the same version.
4. Build a clean consumer from the public sibling tag.

See the [release runbook](../../maintainers/releasing.md) for the full checks
and approval gates.

### 3.3 Diagnostics, suppressions, and fixtures

A finding uses the compiler's line format and includes its rule and DocC URL:

```text
WeatherCard.swift:186:7: error: [primitives-only-in-ops] `refresh` is a demand
on the graph; call a named op from a `CogOps` extension —
https://skeswa.github.io/cog/documentation/cog/primitivesonlyinops
```

All v1 findings are errors. Suppress one finding on the next physical line with
a reason:

```swift
// coglint:disable-next-line <rule> -- <non-empty reason>
```

A bad directive suppresses nothing. There are no global severity settings.

Each rule owns triggering fixtures with exact positions and non-triggering
fixtures for valid code and known syntax-only misses. The same fixtures build
its DocC article. The linter runs its own tests before checking another target.

## 4. The first six rules

A shared classifier finds four kinds of syntax:

- **Cog declaration:** written type or initializer names a Cog declaration
  type, or `.readOnly` projects a known declaration. It handles module names,
  generic arguments, optionals, and `.init`.
- **View:** a type writes `View` conformance or has `body: some View`.
- **Graph receiver:** `@Environment(\.cogs)`, a selector or turn parameter
  named `c`, a mechanism controller, or a local directly returned by
  `Cogs.bootstrapApp`.
- **App entry:** a type writes `App` conformance.

The classifier does not follow assignments or infer across files.

| Rule                         | Required form                                            |
| ---------------------------- | -------------------------------------------------------- |
| `cog-declaration-suffix`     | Keyless names end in `Cog`; box names end in `Cogs`      |
| `no-cogs-in-view-init`       | Views read `Cogs` from the environment                   |
| `primitives-only-in-ops`     | App code calls `turn` and `refresh` only inside `CogOps` |
| `initial-state-in-mechanism` | App bootstrap does no graph work                         |
| `manual-cog-private`         | Writable sources are `private` or `fileprivate`          |
| `no-multi-read-cogs-helper`  | Reads stay flat instead of hiding in a runtime helper    |

### 4.1 `cog-declaration-suffix`

A keyless `Cog`, `Cog<Value>.Manual`, `Cog<Value>.Async`, or projection name
must end in `Cog`. A `CogBox`, `CogBox<Value, Key>.Manual`,
`CogBox<Value, Key>.Async`, or box projection must end in `Cogs`. Put
qualifiers before that suffix.

The classifier reads both the written type and initializer. It does not follow
a declaration copied into a debug seed target.

### 4.2 `no-cogs-in-view-init`

A recognized view must not store `Cogs` or accept it in an initializer or
method parameter. This includes optionals and generic argument positions. Use:

```swift
@Environment(\.cogs) private var cogs
```

A `View` conformance written in another file is a known miss.

### 4.3 `primitives-only-in-ops`

App code may call `turn(...)` or `refresh(...)` only as a bare call inside an
`extension CogOps`. Calls on a known graph receiver fail everywhere else. Bare
or `self.` calls inside `extension Cogs` also fail.

Tests may call primitives directly under their test-role exemption. A nested
writer turn inside a `CogOps` method remains valid.

### 4.4 `initial-state-in-mechanism`

An `App` initializer may bind the result of `Cogs.bootstrapApp(...)` and retain
it. It must not read from it or call a primitive, op, or helper before
retention. Put initial state in a supplied mechanism; `operate` settles before
bootstrap returns.

Service and mechanism setup before bootstrap is valid. Direct retention without
a local is also valid. A factory that hides bootstrap is a known syntax-only
miss.

### 4.5 `manual-cog-private`

Each `Cog<Value>.Manual` and `CogBox<Value, Key>.Manual` declaration must be
`private` or `fileprivate`. Expose `.readOnly` or an automatic cog instead of
the source.

Both access words are valid. At file scope they mean the same thing, and
`swift format` already chooses its preferred spelling.

### 4.6 `no-multi-read-cogs-helper`

A value-returning member of `extension Cogs` or `extension CogOps` fails when
its own body contains two or more graph reads. The rule counts value, status,
and peek reads, but not reads inside nested closures.

Members with no return value, or a written `View`, `some View`, or `Binding`
return type, are outside the rule. The rule does not trace locals through later
assignments.

Declare a true computed value as an automatic cog. Otherwise, read each value
on its own line at the call site.

## 5. V1 limits

- No type data. IndexStoreDB is the planned path if cross-file misses become a
  real problem.
- No autocorrect. `--fix` needs its own rule and fixture contracts.
- No general Swift style. `swift format` owns that work.
- No duplicate compiler rules.
- No SwiftLint regex subset. A second rule surface would drift.

## 6. Use and release

The six rules, all reporters, both plugins, the CLI, DocC pages, artifact tests,
and sibling distribution are implemented. Each rule landed with fixtures and
the same examples in its docs.

The package uses Swift tools 6.2 and Swift 6 mode. Release builds use Xcode
26.6 (17F113) and Swift 6.3.3. The exact pins are:

| Item                    | Pin                                                          |
| ----------------------- | ------------------------------------------------------------ |
| `swift-syntax`          | 603.0.2, revision `79e4b74a295b6eb74a8b585e3a39d29e70c1dbd1` |
| `swift-argument-parser` | 1.8.2, revision `6a52f3251125d74daf04fcbd5e6f08a75d074382`   |
| macOS target            | 14.0                                                         |
| Apple Silicon variant   | `arm64-apple-macosx14.0`                                     |
| Intel variant           | `x86_64-apple-macosx14.0`                                    |

Consumers receive native binaries, so these source dependencies do not need to
match the consumer's Swift compiler.

## 7. Fixed choices and open work

### Names

Users type `coglint`. SwiftPM uses role-specific names:
`CogLintBuildToolPlugin`, `CogLintCommandPlugin`, `CogLintBinary`, and
`CogLintPlugins`. The artifact is `CogLintBinary.artifactbundle.zip`.

### Permanent rule URLs

| Rule                         | URL                                              |
| ---------------------------- | ------------------------------------------------ |
| `cog-declaration-suffix`     | `/cog/documentation/cog/cogdeclarationsuffix`    |
| `no-cogs-in-view-init`       | `/cog/documentation/cog/nocogsinviewinit`        |
| `primitives-only-in-ops`     | `/cog/documentation/cog/primitivesonlyinops`     |
| `initial-state-in-mechanism` | `/cog/documentation/cog/initialstateinmechanism` |
| `manual-cog-private`         | `/cog/documentation/cog/manualcogprivate`        |
| `no-multi-read-cogs-helper`  | `/cog/documentation/cog/nomultireadcogshelper`   |

Each path is under `https://skeswa.github.io`. The docs test checks both the
HTML route and data file. GitHub Pages cannot use DocC redirect metadata as an
HTTP redirect, so a future move must ship a real redirect first.

### Why the sibling package is required

A measured fixture put the binary target in Cog's root manifest but did not
apply either plugin. Both SwiftPM and Xcode still fetched the binary:

| Test                  | Result                                                  |
| --------------------- | ------------------------------------------------------- |
| SwiftPM resolve       | Tried the unused URL and failed after 0.68 seconds      |
| SwiftPM release build | Required the unused binary and failed after 1.6 seconds |
| Xcode workspace build | Failed package resolution after 1.9 seconds             |

The two probe binaries already totaled 39,104,024 bytes before bundling.
Keeping the binary in the root package would charge every Cog user for an
unused tool and could break a normal resolve. The sibling package avoids that.

### Open work

Possible later rules cover local names after reads, per-view environment use,
`fatalError`, explicit class deinits, and `@testable import Cog` in scenario
tests. Type-aware analysis, autocorrect, a SwiftLint subset, and Kotlin lint
timing also remain open.
