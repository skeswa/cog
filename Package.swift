// swift-tools-version:6.2

import PackageDescription

// MARK: - Shared Swift settings

/// Settings applied to every shipped library target.
///
/// These language and isolation flags never vary. The `CompactArena` package
/// trait adds its conditional setting farther below.
let baseLibrarySettings: [SwiftSetting] = [
  .swiftLanguageMode(.v6),
  .defaultIsolation(MainActor.self),
  .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("MemberImportVisibility"),
  .enableUpcomingFeature("InternalImportsByDefault"),
]

// MARK: - The isolation matrix

// The same test targets compile in four legs: {MainActor-default, nonisolated}
// × {`NonisolatedNonsendingByDefault` on, off}. The two environment variables
// below select the leg. `tools/swift-test.mjs` sets them; an
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
// Xcode's generated package scheme builds every test target before applying
// `-only-testing`. Exit tests are unavailable on iOS, so the simulator runner
// asks the manifest for the one test target that is valid there.
let simulatorBoundaryOnly = Context.environment["COG_SIMULATOR_BOUNDARY_ONLY"] == "1"

/// Settings applied to every test target, for the leg the environment selects.
///
/// Only test-target isolation varies here. The shipped library keeps its fixed
/// MainActor isolation while representation selectors are assembled below.
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

// MARK: - Retired experiment selectors

// Keep explicit tombstones for old comparison commands. Silently ignoring an
// exported selector would make a stale benchmark appear to measure a candidate
// that no longer exists.

if let retiredCore = Context.environment["COG_TEST_CORE"] {
  fatalError(
    """
    COG_TEST_CORE=\(retiredCore) is no longer supported because the simple core was retired. \
    Unset COG_TEST_CORE; use the CompactArena package trait for the supported compact build.
    """
  )
}

if let retiredEdge = Context.environment["COG_TEST_EDGE"] {
  fatalError(
    """
    COG_TEST_EDGE=\(retiredEdge) is no longer supported because shared pool edges were \
    selected and the losing candidates were retired. Unset COG_TEST_EDGE.
    """
  )
}

if let retiredSpecialization = Context.environment["COG_TEST_ARENA_SPECIALIZATION"] {
  fatalError(
    """
    COG_TEST_ARENA_SPECIALIZATION=\(retiredSpecialization) is no longer supported. \
    Unset it; use the CompactArena package trait for the supported compact build.
    """
  )
}

if let retiredValueReferenceLayout = Context.environment["COG_TEST_VALUE_REFERENCE_LAYOUT"] {
  fatalError(
    """
    COG_TEST_VALUE_REFERENCE_LAYOUT=\(retiredValueReferenceLayout) is no longer supported \
    because inline AnyHashable keys were selected and the losing candidates were retired. \
    Unset COG_TEST_VALUE_REFERENCE_LAYOUT.
    """
  )
}

// MARK: - Arena specialization trait

// The only implementation uses a specialized arena with shared pool edges and
// inline AnyHashable keys. The non-default CompactArena trait reduces binary
// size by disabling specialization. It does not change the arena or public API.

/// Settings contributed by the public binary-size opt-out trait.
let compactArenaTraitSettings: [SwiftSetting] = [
  .define("COG_ARENA_COMPACT", .when(traits: ["CompactArena"]))
]

/// Trait choices mirrored into tests for the selector sentinel.
let compactArenaTraitTestSettings: [SwiftSetting] = [
  .define("COG_LEG_ARENA_COMPACT", .when(traits: ["CompactArena"]))
]

/// Library settings plus the public binary-size trade.
///
/// The base flags never vary. `CompactArena` is the sole representation
/// choice and suppresses only the specialization attributes.
let librarySettings: [SwiftSetting] = baseLibrarySettings + compactArenaTraitSettings
testSettings += compactArenaTraitTestSettings

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
    // Not API. Exists so the separate `swift/Benchmarks/Runner` package can share the
    // scenario graphs with `CogScenarioTests`.
    .library(name: "_CogScenarios", targets: ["CogScenarios"]),
  ],
  traits: [
    .trait(
      name: "CompactArena",
      description: "Reduce generated code size by disabling the arena's specialization frontier."
    )
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
      name: "CogBoundaryTests",
      dependencies: ["Cog", "CogTesting"],
      path: "swift/Tests/CogBoundaryTests",
      swiftSettings: testSettings
    ),
  ]
    + (simulatorBoundaryOnly
      ? []
      : [
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
      ])
)
