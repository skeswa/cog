# Cog lint development package

`CogLint` is a separate SwiftPM package so swift-syntax and
swift-argument-parser remain outside the dependency graph resolved by a Cog
library consumer. Its sole product is the `coglint` executable. `CogLintCore`
is a package-only implementation target shared with fixture tests; it is not a
consumer product.

The manifest uses Swift tools 6.2, Swift 6 language mode, macOS 14, exact
swift-syntax 603.0.2 and swift-argument-parser 1.8.2 pins. Its committed
`Package.resolved` makes the corresponding revisions part of the release
toolchain contract.

Until M8-02b adds the guarded test wrapper, build and run the unfiltered
scaffold tests from the repository root with:

```console
swift package --package-path swift/Lint build
swift package --package-path swift/Lint test
```

`rootManifestExcludesLintDependencies` removes the opt-in DocC environment
gate and asks SwiftPM for the root package's JSON dependency graph. The test
requires that graph to contain only `cog`, while this nested package resolves
the two exact source dependencies above. That is the executable assertion for
the one-way package boundary: lint depends on its tools; Cog never does.
