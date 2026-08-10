// swift-tools-version:6.2

import PackageDescription

// MARK: - Shared Swift settings

/// Settings applied to every shipped library target.
///
/// The library flags never vary. Only the *test* targets change shape across
/// the isolation matrix (see `testSettings` below).
let librarySettings: [SwiftSetting] = [
  .swiftLanguageMode(.v6),
  .defaultIsolation(MainActor.self),
  .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("MemberImportVisibility"),
  .enableUpcomingFeature("InternalImportsByDefault"),
]

/// Settings applied to every test target.
///
/// Today this is the default leg of the isolation matrix: MainActor-by-default
/// with `NonisolatedNonsendingByDefault` on. `M0-04` replaces the constants
/// below with values selected from `COG_TEST_ISOLATION` and `COG_TEST_NNBD`
/// and mirrors each leg into a `.define()`; nothing else in this manifest has
/// to move when it does.
let testSettings: [SwiftSetting] = [
  .swiftLanguageMode(.v6),
  .defaultIsolation(MainActor.self),
  .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

// MARK: - Optional dependencies

/// swift-docc-plugin is env-gated so that the default resolve of this package
/// is dependency-free for consumers. Only the docs workflow sets `COG_DOCC=1`.
///
/// swift-docc-plugin vends a *command* plugin, which SwiftPM makes available
/// to the whole package from the dependency alone; no target `plugins:` entry
/// is required (or correct) for it.
var packageDependencies: [Package.Dependency] = []
if Context.environment["COG_DOCC"] == "1" {
  packageDependencies.append(
    .package(url: "https://github.com/apple/swift-docc-plugin.git", from: "1.4.3")
  )
}

// MARK: - Package

let package = Package(
  name: "cog",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
  ],
  products: [
    .library(name: "Cog", targets: ["Cog"]),
    .library(name: "CogTesting", targets: ["CogTesting"]),
    // Not API. Exists so the separate `swift/Benchmarks` package can share the
    // scenario graphs with `CogScenarioTests`.
    .library(name: "_CogScenarios", targets: ["CogScenarios"]),
  ],
  dependencies: packageDependencies,
  targets: [
    .target(
      name: "Cog",
      path: "swift/Sources/Cog",
      swiftSettings: librarySettings
    ),
    .target(
      name: "CogTesting",
      dependencies: ["Cog"],
      path: "swift/Sources/CogTesting",
      swiftSettings: librarySettings
    ),
    .target(
      name: "CogScenarios",
      dependencies: ["Cog"],
      path: "swift/Sources/CogScenarios",
      swiftSettings: librarySettings
    ),
    .testTarget(
      name: "CogTests",
      dependencies: ["Cog", "CogTesting"],
      path: "swift/Tests/CogTests",
      swiftSettings: testSettings
    ),
    .testTarget(
      name: "CogScenarioTests",
      dependencies: ["Cog", "CogTesting", "CogScenarios"],
      path: "swift/Tests/CogScenarioTests",
      swiftSettings: testSettings
    ),
    .testTarget(
      name: "CogBoundaryTests",
      dependencies: ["Cog", "CogTesting"],
      path: "swift/Tests/CogBoundaryTests",
      swiftSettings: testSettings
    ),
  ]
)
