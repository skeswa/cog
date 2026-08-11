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

// MARK: - The isolation matrix

// The same test targets compile in four legs — {MainActor-default,
// nonisolated} × {`NonisolatedNonsendingByDefault` on, off} — selected by the
// two environment variables read below. `tools/swift-test.mjs` sets them; an
// unset variable is the default leg, so a bare `swift test` still works.
//
// Each leg is also mirrored into a `.define()`, which is what lets the LEG-02
// test in `CogTests` prove the leg it was compiled for matches the leg its
// environment asked for. Without the defines, a manifest that quietly stopped
// reading the environment would collapse the matrix into four identical runs
// that all still pass.
//
// An unrecognized value is a hard error rather than a silent fall back to the
// default leg: a typo in a CI matrix entry would otherwise buy a green from a
// leg that never ran.

let requestedIsolation = Context.environment["COG_TEST_ISOLATION"] ?? "mainactor"
let requestedNonisolatedNonsending = Context.environment["COG_TEST_NNBD"] ?? "1"

/// Settings applied to every test target, for the leg the environment selects.
///
/// Only the *test* targets vary; `librarySettings` above is fixed, because the
/// shipped library has exactly one shape no matter how it is tested.
var testSettings: [SwiftSetting] = [
  .swiftLanguageMode(.v6)
]

switch requestedIsolation {
case "mainactor":
  testSettings.append(.defaultIsolation(MainActor.self))
  testSettings.append(.define("COG_LEG_ISOLATION_MAINACTOR"))
case "nonisolated":
  // SE-0466 spells "no default actor isolation" as a nil isolation, which
  // SwiftPM lowers to `-default-isolation nonisolated`.
  testSettings.append(.defaultIsolation(nil))
  testSettings.append(.define("COG_LEG_ISOLATION_NONISOLATED"))
default:
  fatalError(
    """
    COG_TEST_ISOLATION was \(requestedIsolation), which is not an isolation leg. \
    Expected mainactor or nonisolated, or leave it unset for mainactor.
    """
  )
}

switch requestedNonisolatedNonsending {
case "1":
  testSettings.append(.enableUpcomingFeature("NonisolatedNonsendingByDefault"))
  testSettings.append(.define("COG_LEG_NNBD_ON"))
case "0":
  testSettings.append(.define("COG_LEG_NNBD_OFF"))
default:
  fatalError(
    """
    COG_TEST_NNBD was \(requestedNonisolatedNonsending), which is not a \
    NonisolatedNonsendingByDefault leg. Expected 1 or 0, or leave it unset for 1.
    """
  )
}

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
