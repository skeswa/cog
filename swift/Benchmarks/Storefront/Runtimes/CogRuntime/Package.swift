// swift-tools-version:6.2

import PackageDescription

// The Cog implementation of the neutral Storefront workload.
//
// Keeping this port outside the workload package makes neutrality a package-
// graph property rather than merely a target-level convention. Only this
// runtime and its consumers resolve Cog and CogTesting.

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
  name: "cog-storefront",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
  ],
  products: [
    .library(name: "CogStorefront", targets: ["CogStorefront"])
  ],
  dependencies: [
    .package(name: "cog", path: "../../../../.."),
    .package(name: "cog-storefront-workload", path: "../../Workload"),
  ],
  targets: [
    .target(
      name: "CogStorefront",
      dependencies: [
        .product(name: "StorefrontWorkload", package: "cog-storefront-workload"),
        .product(name: "Cog", package: "cog"),
        .product(name: "CogTesting", package: "cog"),
      ],
      swiftSettings: storefrontSwiftSettings
    ),
    .testTarget(
      name: "CogStorefrontTests",
      dependencies: [
        "CogStorefront",
        .product(name: "StorefrontWorkload", package: "cog-storefront-workload"),
        .product(name: "Cog", package: "cog"),
        .product(name: "CogTesting", package: "cog"),
      ],
      swiftSettings: storefrontSwiftSettings
    ),
  ]
)
