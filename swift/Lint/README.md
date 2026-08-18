# Cog lint development package

`CogLint` is a separate SwiftPM package so swift-syntax and
swift-argument-parser remain outside the dependency graph resolved by a Cog
library consumer. Its sole product is the `coglint` executable. `CogLintCore`
is the package-only rule and parser target. `CogLintFixtures` is another
package-only target holding the executable fixture model, validator, and DocC
fragment renderer, so rule tests and generated documentation consume one
corpus. Neither target is a consumer product.

The manifest uses Swift tools 6.2, Swift 6 language mode, macOS 14, exact
swift-syntax 603.0.2 and swift-argument-parser 1.8.2 pins. Its committed
`Package.resolved` makes the corresponding revisions part of the release
toolchain contract.

Build the executable and run the guarded tests from the repository root with:

```console
swift package --package-path swift/Lint build
swift run --package-path swift/Lint coglint swift/Sources
mise run test:lint
mise run lint:swift
mise run build:lint-artifact
mise run test:lint-artifact
mise run test:lint-build-tool-plugin
mise run test:lint-command-plugin
mise run build:lint-distribution
mise run test:lint-distribution
mise run build:lint-documentation
mise run test:lint-documentation
```

`mise run lint:swift` first runs the guarded package suite, then checks root
library and Weather production targets with the production role and their
tracked unit test targets with the explicit test role. Empty Xcode-created
target directories are not inputs; CogLint keeps rejecting every named path
that does not exist. Compile-fail fixtures and benchmark workloads are not
target sources and stay outside the dogfood pass.

The artifact build produces separate native macOS 14 `arm64` and `x86_64`
executables, the release `.artifactbundle.zip`, and its SwiftPM checksum under
`swift/Lint/Artifacts`. The generated products are ignored. The artifact suite
rebuilds them and runs a scratch SwiftPM command plugin under both arm64 and
Rosetta, requiring the selected path to name the matching metadata variant and
the selected executable to serve its real CLI help.

The build-tool plugin receives the exact Swift membership of its target and
runs the binary in Xcode reporter mode before compilation. It keeps a
content-addressed result under the target-specific plugin work directory. An
unchanged build replays the same diagnostics and failing status without
reparsing; the LINT-17 suite proves that behavior in both a scratch SwiftPM
package and a macOS Xcode project.

The command plugin is a transparent on-demand adapter: `swift package
coglint` forwards the bare CLI arguments, runs from the consumer package, and
preserves reporter output and status. The LINT-18 suite compares both surfaces
under production and test target roles with Xcode, GitHub, and SARIF reporters.

Channel B is generated with `mise run build:lint-distribution` after the
artifact build supplies its checksum. The output contains only the remote
binary target, both checked-in plugin adapters, the repository license, and a
machine-readable generation record. `mise run test:lint-distribution` proves
this sibling stays outside an ordinary Cog consumer’s resolve, fetch, and
source-dependency graph while retaining the eager binary fetch that makes the
explicit sibling boundary necessary.

The rule-reference articles are generated with
`mise run build:lint-documentation`. Their violation, rationale, repair, and
code examples all come from `CogLintFixtures`; the checked-in Markdown is a
release input, not another editable copy. `mise run test:lint-documentation`
regenerates the six articles in scratch space, requires byte identity, builds
the statically hosted DocC archive, and checks each diagnostic URL’s HTML route,
data payload, and rendered code listings.

`coglint` accepts an explicit mix of Swift files and directories. Directories
are searched recursively, hidden descendants are skipped, overlapping inputs
are deduplicated, and diagnostics are ordered by path and source position.
Every error uses Xcode's `path:line:column: error:` grammar and includes its
rule slug and permanent DocC help URL.

Production is the default target role. Pass `--target-role test` only for test
target sources; role is explicit invocation configuration and is never guessed
from a file path. A suppression must use the exact next-physical-line form
`// coglint:disable-next-line <rule> -- <non-empty reason>`. It names one rule,
does not cross a blank or comment line, and a malformed attempt suppresses
nothing.

Extra test arguments pass through, including scenario filters such as
`mise run test:lint --filter LINT-02`. The wrapper enumerates tests before the
run, rejects an unmatched filter or unmatched top-level alternative, and
requires its xUnit report to contain a nonzero authoritative executed count.

`rootManifestExcludesLintDependencies` removes the opt-in DocC environment
gate and asks SwiftPM for the root package's JSON dependency graph. The test
requires a root named `cog` with no dependency children; it does not assume the
checkout directory supplies that identity. This nested package resolves the
two exact source dependencies above. That is the executable assertion for the
one-way package boundary: lint depends on its tools; Cog never does.
