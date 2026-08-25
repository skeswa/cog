// swift-tools-version:6.2

import PackageDescription

// The two plain-Swift Storefront comparison runtimes.
//
// Raw and memoized Observation stay in separate targets so the raw floor
// cannot reach the memo implementation's caches. This package depends only on
// the neutral workload; resolving it does not resolve Cog or swift-state-graph.

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
  name: "cog-storefront-observation",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
  ],
  products: [
    .library(name: "StorefrontObservationRaw", targets: ["StorefrontObservationRaw"]),
    .library(name: "StorefrontObservationMemo", targets: ["StorefrontObservationMemo"]),
  ],
  dependencies: [
    .package(name: "cog-storefront-workload", path: "../../Workload")
  ],
  targets: [
    .target(
      name: "StorefrontObservationRaw",
      dependencies: [
        .product(name: "StorefrontWorkload", package: "cog-storefront-workload")
      ],
      swiftSettings: storefrontSwiftSettings
    ),
    .target(
      name: "StorefrontObservationMemo",
      dependencies: [
        .product(name: "StorefrontWorkload", package: "cog-storefront-workload")
      ],
      swiftSettings: storefrontSwiftSettings
    ),
    .testTarget(
      name: "StorefrontRuntimesTests",
      dependencies: [
        "StorefrontObservationRaw",
        "StorefrontObservationMemo",
        .product(name: "StorefrontWorkload", package: "cog-storefront-workload"),
      ],
      swiftSettings: storefrontSwiftSettings
    ),
  ]
)
