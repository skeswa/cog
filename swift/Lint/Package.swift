// swift-tools-version:6.2

import PackageDescription

// CogLint is a development package of its own because its parser and CLI
// dependencies must never enter the graph resolved by an ordinary Cog
// consumer. The root package does not reference this directory; the checked-in
// isolation test below verifies that one-way boundary through SwiftPM itself.
// Exact pins make the generated binary, fixtures, and syntax tree API one
// reproducible release unit.
let package = Package(
  name: "CogLint",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "coglint", targets: ["coglint"])
  ],
  dependencies: [
    .package(
      url: "https://github.com/swiftlang/swift-syntax.git",
      exact: "603.0.2"
    ),
    .package(
      url: "https://github.com/apple/swift-argument-parser.git",
      exact: "1.8.2"
    ),
  ],
  targets: [
    .target(
      name: "CogLintCore",
      dependencies: [
        .product(name: "SwiftParser", package: "swift-syntax"),
        .product(name: "SwiftSyntax", package: "swift-syntax"),
      ]
    ),
    .target(
      name: "CogLintFixtures",
      dependencies: [
        "CogLintCore",
        .product(name: "SwiftSyntax", package: "swift-syntax"),
      ]
    ),
    .executableTarget(
      name: "coglint",
      dependencies: [
        "CogLintCore",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
    .testTarget(
      name: "CogLintTests",
      dependencies: [
        "CogLintCore",
        "CogLintFixtures",
        .product(name: "SwiftSyntax", package: "swift-syntax"),
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
