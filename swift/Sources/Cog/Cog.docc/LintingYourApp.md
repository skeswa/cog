# Linting your app

Turn Cog's source conventions into build-time diagnostics without adding the
linter to the dependency graph of an ordinary Cog consumer.

## Overview

CogLint is distributed separately from the `Cog` library. The source, rule
fixtures, documentation, and releases live with Cog, while the generated
`CogLintPlugins` package contains only two plugin adapters and a checksummed
binary target. Add that package only to projects that want linting, and pin it
to exactly the same version as Cog.

### Add the build-tool plugin

For SwiftPM, add both version-matched packages and attach
`CogLintBuildToolPlugin` to each source target you want checked:

```swift
// x-release-please-start-version
dependencies: [
  .package(
    url: "https://github.com/skeswa/cog.git",
    .upToNextMinor(from: "0.5.0")
  ),
  .package(
    url: "https://github.com/skeswa/coglint-plugins.git",
    exact: "0.5.0"
  ),
],
// x-release-please-end
targets: [
  .target(
    name: "ForecastFeature",
    dependencies: [
      .product(name: "Cog", package: "cog")
    ],
    plugins: [
      .plugin(
        name: "CogLintBuildToolPlugin",
        package: "coglint-plugins"
      )
    ]
  ),
]
```

SwiftPM tells the plugin whether a source module is a production or test
target. Production targets enforce every rule; test targets receive only the
documented primitive-call exemption. The plugin passes the target's exact
Swift membership to the native binary and replays cached diagnostics on an
unchanged build.

In Xcode, add `https://github.com/skeswa/coglint-plugins.git` at the exact Cog
version, then add `CogLintBuildToolPlugin` under the target's build-tool
plugins. Xcode does not expose a test-target role to this plugin, so an Xcode
target is checked conservatively as production. Use the command plugin with an
explicit test role when test sources need the primitive exemption.

### Run the command plugin

The same package exposes an on-demand command. From a Swift package that has
the plugin dependency, run:

```console
swift package coglint Sources --target-role production --reporter xcode
swift package coglint Tests --target-role test --reporter xcode
```

Inputs may mix files and directories. Directories are searched recursively,
hidden descendants are skipped, overlapping inputs are deduplicated, and
findings are ordered by path and source position. Choose `xcode`, `github`, or
`sarif` without changing which findings fail the command. Keep production and
test inputs in separate invocations so each receives its explicit role.

### Act on a finding

Every diagnostic names its rule and links to one of the articles below. The
article explains the violation, why the convention exists, and the expected
repair using examples from the same fixture corpus that tests the rule.

Suppress an intentional exception only on the next physical line, naming one
rule and a non-empty reason:

```swift
// coglint:disable-next-line primitives-only-in-ops -- low-level boundary proof
c.turn { writer in writer[countSourceCog] += 1 }
```

A malformed directive suppresses nothing. Prefer the rule's repair whenever
the exception is not itself the point of the code.

## Topics

### Rule reference

- <doc:CogDeclarationSuffix>
- <doc:NoCogsInViewInit>
- <doc:PrimitivesOnlyInOps>
- <doc:InitialStateInMechanism>
- <doc:ManualCogPrivate>
- <doc:NoMultiReadCogsHelper>
