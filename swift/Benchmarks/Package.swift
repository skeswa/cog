// swift-tools-version:6.2

import PackageDescription

// A package of its own, deliberately, and this file is the whole reason.
//
// Benchmarking needs a harness, an allocator backend, and eventually a
// baseline-checking CLI. None of that belongs in the dependency graph a
// consumer resolves: SwiftPM gives a package's dependencies to everyone who
// resolves it, so a benchmark dependency added to the root manifest would
// reach every app that adds Cog. The root package resolves with **no**
// dependencies at all (swift-docc-plugin is environment-gated behind
// `COG_DOCC=1` for the same reason), and keeping that true is a shipped
// property rather than a tidiness preference.
//
// The relationship only runs one way: this package depends on the root by
// path, and nothing in the root references this directory. `M5-05a` proves
// that by describing both manifests and reading the root's dependency graph.
//
// The pinned benchmark dependency and allocator backend arrive in `M5-05c`,
// after `M5-05ba` and `M5-05bb` verify what to pin. Until then this is a shell
// that builds, runs a shared scenario, and demonstrates the isolation.

let package = Package(
  name: "cog-benchmarks",
  // Host-only. Benchmarks measure the graph, which is platform-independent
  // MainActor code, so there is nothing an iOS destination would add beyond
  // simulator noise.
  platforms: [.macOS(.v14)],
  dependencies: [
    // The one and only dependency, and it is a local path — never a version.
    // Benchmarks measure the working tree, so resolving Cog from a tag would
    // make every measurement a statement about a commit that is not the one
    // being changed.
    .package(path: "../..")
  ],
  targets: [
    .executableTarget(
      name: "CogBenchmarks",
      dependencies: [
        .product(name: "Cog", package: "cog"),
        .product(name: "CogTesting", package: "cog"),
        // The shared scenario graphs. Sharing them with `CogScenarioTests` is
        // the point: a run-count assertion and a timing measurement that
        // disagreed about which graph they ran would make both meaningless.
        .product(name: "_CogScenarios", package: "cog"),
      ],
      path: "Sources/CogBenchmarks",
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .defaultIsolation(MainActor.self),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
        .enableUpcomingFeature("ExistentialAny"),
        .enableUpcomingFeature("MemberImportVisibility"),
        .enableUpcomingFeature("InternalImportsByDefault"),
      ]
    )
  ]
)
