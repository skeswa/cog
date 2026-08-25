// swift-tools-version:6.2

import PackageDescription

// Cross-runtime correctness lives beside the Storefront suite rather than in
// the benchmark runner. This package is the intentional integration point where
// all four implementations coexist; none of the runtime packages can import a
// sibling implementation.

/// The dialect used to drive each runtime through the neutral async protocol.
let agreementSwiftSettings: [SwiftSetting] = [
  .swiftLanguageMode(.v6),
  .defaultIsolation(MainActor.self),
  .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("MemberImportVisibility"),
  .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
  name: "cog-storefront-verification",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(name: "cog-storefront-workload", path: "../Workload"),
    .package(name: "cog-storefront", path: "../Runtimes/CogRuntime"),
    .package(name: "cog-storefront-observation", path: "../Runtimes/Observation"),
    .package(name: "cog-storefront-state-graph", path: "../Runtimes/StateGraph"),
  ],
  targets: [
    .testTarget(
      name: "StorefrontAgreementTests",
      dependencies: [
        .product(name: "StorefrontWorkload", package: "cog-storefront-workload"),
        .product(name: "CogStorefront", package: "cog-storefront"),
        .product(name: "StorefrontObservationRaw", package: "cog-storefront-observation"),
        .product(name: "StorefrontObservationMemo", package: "cog-storefront-observation"),
        .product(name: "StorefrontStateGraph", package: "cog-storefront-state-graph"),
      ],
      swiftSettings: agreementSwiftSettings
    )
  ]
)
