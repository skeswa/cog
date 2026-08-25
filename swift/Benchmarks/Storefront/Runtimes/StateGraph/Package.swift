// swift-tools-version:6.2

import PackageDescription

// The swift-state-graph implementation of the neutral Storefront workload.
//
// It is a package of its own so its exact library and macro-toolchain pins reach
// only consumers that select this runtime. The Observation and Cog packages do
// not resolve swift-state-graph.

/// The build shape shared by every Storefront workload and runtime target.
let storefrontSwiftSettings: [SwiftSetting] = [
  .swiftLanguageMode(.v6),
  .defaultIsolation(MainActor.self),
  .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("MemberImportVisibility"),
  .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
  name: "cog-storefront-state-graph",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
  ],
  products: [
    .library(name: "StorefrontStateGraph", targets: ["StorefrontStateGraph"])
  ],
  dependencies: [
    .package(name: "cog-storefront-workload", path: "../../Workload"),
    .package(
      url: "https://github.com/VergeGroup/swift-state-graph",
      exact: "0.28.0"
    ),
  ],
  targets: [
    .target(
      name: "StorefrontStateGraph",
      dependencies: [
        .product(name: "StorefrontWorkload", package: "cog-storefront-workload"),
        .product(name: "StateGraph", package: "swift-state-graph"),
      ],
      swiftSettings: storefrontSwiftSettings
    ),
    .testTarget(
      name: "StorefrontStateGraphTests",
      dependencies: [
        "StorefrontStateGraph",
        .product(name: "StorefrontWorkload", package: "cog-storefront-workload"),
        .product(name: "StateGraph", package: "swift-state-graph"),
      ],
      swiftSettings: storefrontSwiftSettings
    ),
  ]
)
