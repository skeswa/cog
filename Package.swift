// swift-tools-version:6.2

import PackageDescription

// MARK: - Shared Swift settings

/// Settings applied to every shipped library target.
///
/// The library flags never vary. Only the *test* targets change shape across
/// the isolation matrix (see `testSettings` below).
let baseLibrarySettings: [SwiftSetting] = [
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
// Xcode's generated package scheme builds every test target before applying
// `-only-testing`. Exit tests are unavailable on iOS, so the simulator runner
// asks the manifest for the one test target that is valid there.
let simulatorBoundaryOnly = Context.environment["COG_SIMULATOR_BOUNDARY_ONLY"] == "1"

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

// MARK: - The value-reference layout seam

// M5-09e selected inline `AnyHashable` as the shipping value-reference layout
// (perf §4, §9.6). The selector remains so the complete behavior suite and
// recorded benchmark shapes can keep exercising the rejected interned-token
// and generic-keyed candidates: read an environment variable, lower it to a
// define, and fail loudly on anything unrecognized.
//
// This is a *library* setting rather than a test setting, because the layout is
// part of the library's representation — a test cannot choose it for code it did
// not compile. It is test-and-benchmark-only in intent: unset means the
// selected `inline` layout, so an ordinary consumer never opts into a losing
// candidate or its conditional public surface.
//
// A typo is a hard error rather than a fall back to `inline`, for the reason the
// isolation legs give: a mistyped candidate would otherwise buy a green from a
// layout that never ran.

let requestedValueReferenceLayout =
  Context.environment["COG_TEST_VALUE_REFERENCE_LAYOUT"] ?? "inline"

var valueReferenceLayoutSettings: [SwiftSetting] = []

/// The layout, mirrored into the *test* targets so a test can compare what the
/// environment asked for with what the library was actually built as.
var valueReferenceLayoutTestSettings: [SwiftSetting] = []

switch requestedValueReferenceLayout {
case "inline":
  valueReferenceLayoutSettings.append(.define("COG_VALUE_REFERENCE_LAYOUT_INLINE"))
  valueReferenceLayoutTestSettings.append(.define("COG_LEG_VALUE_REFERENCE_LAYOUT_INLINE"))
case "interned":
  valueReferenceLayoutSettings.append(.define("COG_VALUE_REFERENCE_LAYOUT_INTERNED"))
  valueReferenceLayoutTestSettings.append(.define("COG_LEG_VALUE_REFERENCE_LAYOUT_INTERNED"))
case "generic":
  valueReferenceLayoutSettings.append(.define("COG_VALUE_REFERENCE_LAYOUT_GENERIC"))
  valueReferenceLayoutTestSettings.append(.define("COG_LEG_VALUE_REFERENCE_LAYOUT_GENERIC"))
default:
  fatalError(
    """
    COG_TEST_VALUE_REFERENCE_LAYOUT was \(requestedValueReferenceLayout), which is not a \
    value-reference layout candidate. Expected inline, interned, or generic, or leave \
    it unset for inline.
    """
  )
}

// MARK: - The core and edge representation seams

// M6 builds the arena vertically while the class-state correctness core remains
// the shipping default. These selectors are library settings because they
// choose the representation that implements Cogs, not merely which tests run.
// Mirrored test defines let a sentinel prove that the runner, test target, and
// library all selected the same implementation.
//
// An arena build without an explicit edge uses `pool`, its first runnable
// candidate. Naming an edge beside `simple` is an error: accepting it would let
// a candidate command go green without compiling or exercising that candidate.

let requestedCore = Context.environment["COG_TEST_CORE"] ?? "simple"
let requestedEdge = Context.environment["COG_TEST_EDGE"]

var coreSettings: [SwiftSetting] = []
var edgeSettings: [SwiftSetting] = []
var coreTestSettings: [SwiftSetting] = []
var edgeTestSettings: [SwiftSetting] = []

switch requestedCore {
case "simple":
  if let requestedEdge {
    fatalError(
      """
      COG_TEST_EDGE was \(requestedEdge), but edge layouts belong only to the arena core. \
      Unset COG_TEST_EDGE or select COG_TEST_CORE=arena.
      """
    )
  }
  coreSettings.append(.define("COG_CORE_SIMPLE"))
  coreTestSettings.append(.define("COG_LEG_CORE_SIMPLE"))
case "arena":
  coreSettings.append(.define("COG_CORE_ARENA"))
  coreTestSettings.append(.define("COG_LEG_CORE_ARENA"))

  switch requestedEdge ?? "pool" {
  case "pool":
    edgeSettings.append(.define("COG_EDGE_POOL"))
    edgeTestSettings.append(.define("COG_LEG_EDGE_POOL"))
  case "prefix":
    edgeSettings.append(.define("COG_EDGE_PREFIX"))
    edgeTestSettings.append(.define("COG_LEG_EDGE_PREFIX"))
  case "inline":
    edgeSettings.append(.define("COG_EDGE_INLINE"))
    edgeTestSettings.append(.define("COG_LEG_EDGE_INLINE"))
  default:
    fatalError(
      """
      COG_TEST_EDGE was \(requestedEdge ?? "nil"), which is not an implemented arena edge \
      candidate. Expected pool, prefix, or inline, or leave it unset for pool.
      """
    )
  }
default:
  fatalError(
    """
    COG_TEST_CORE was \(requestedCore), which is not a core implementation. Expected \
    simple or arena, or leave it unset for simple.
    """
  )
}

/// Library settings plus the selected value-reference, core, and edge layouts.
///
/// The base flags never vary. Unset selectors choose the shipping simple core
/// and inline value-reference layout; arena candidates are test-only until M6's
/// measurement gate records otherwise.
let librarySettings: [SwiftSetting] =
  baseLibrarySettings + valueReferenceLayoutSettings + coreSettings + edgeSettings
testSettings += valueReferenceLayoutTestSettings + coreTestSettings + edgeTestSettings

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
