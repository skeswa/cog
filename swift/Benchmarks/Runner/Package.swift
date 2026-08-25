// swift-tools-version:6.2

import PackageDescription

// The headless benchmark runner is a package of its own so its measurement
// harness, malloc interposer, and comparison libraries never enter the graph a
// Cog consumer resolves. The relationship points one way: this package depends
// on the working tree and on Storefront's independently usable packages.

/// The nonisolated Swift 6 build shape required by Benchmark's generated entry points.
let benchmarkSwiftSettings: [SwiftSetting] = [
  .swiftLanguageMode(.v6),
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("MemberImportVisibility"),
  .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
  name: "cog-benchmarks",
  platforms: [.macOS(.v14)],
  traits: [
    .trait(name: "CompactArena")
  ],
  dependencies: [
    .package(
      name: "cog",
      path: "../../..",
      traits: [
        .trait(name: "CompactArena", condition: .when(traits: ["CompactArena"]))
      ]
    ),
    .package(name: "cog-storefront-workload", path: "../Storefront/Workload"),
    .package(name: "cog-storefront", path: "../Storefront/Runtimes/CogRuntime"),
    .package(
      name: "cog-storefront-observation",
      path: "../Storefront/Runtimes/Observation"
    ),
    .package(
      name: "cog-storefront-state-graph",
      path: "../Storefront/Runtimes/StateGraph"
    ),
    .package(
      url: "https://github.com/VergeGroup/swift-state-graph",
      exact: "0.28.0"
    ),
    .package(url: "https://github.com/ordo-one/benchmark", exact: "1.36.2"),
  ],
  targets: [
    // Cog-specific allocation, graph-shape, layout, boundary, and memory cuts.
    .executableTarget(
      name: "CogCore",
      dependencies: [
        .product(name: "Benchmark", package: "benchmark"),
        .product(name: "Cog", package: "cog"),
        .product(name: "CogTesting", package: "cog"),
        .product(name: "_CogScenarios", package: "cog"),
      ],
      path: "Benchmarks/CogCore",
      swiftSettings: benchmarkSwiftSettings,
      plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]
    ),
    // Synthetic graph shapes shared by Cog, raw Observation, and StateGraph.
    .executableTarget(
      name: "RuntimeComparison",
      dependencies: [
        .product(name: "Benchmark", package: "benchmark"),
        .product(name: "Cog", package: "cog"),
        .product(name: "CogTesting", package: "cog"),
        .product(name: "StateGraph", package: "swift-state-graph"),
      ],
      path: "Benchmarks/RuntimeComparison",
      swiftSettings: benchmarkSwiftSettings,
      plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]
    ),
    // The application-shaped Storefront cuts across all four implementations.
    .executableTarget(
      name: "Storefront",
      dependencies: [
        .product(name: "Benchmark", package: "benchmark"),
        .product(name: "Cog", package: "cog"),
        .product(name: "CogStorefront", package: "cog-storefront"),
        .product(name: "StorefrontWorkload", package: "cog-storefront-workload"),
        .product(
          name: "StorefrontObservationRaw",
          package: "cog-storefront-observation"
        ),
        .product(
          name: "StorefrontObservationMemo",
          package: "cog-storefront-observation"
        ),
        .product(
          name: "StorefrontStateGraph",
          package: "cog-storefront-state-graph"
        ),
      ],
      path: "Benchmarks/Storefront",
      swiftSettings: benchmarkSwiftSettings,
      plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]
    ),
  ]
)
