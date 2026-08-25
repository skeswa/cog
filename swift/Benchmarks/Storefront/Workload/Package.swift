// swift-tools-version:6.2

import PackageDescription

// The dependency-free contract shared by every Storefront implementation.
//
// This package owns the domain model, deterministic fixtures, scripted service,
// shadow model, runtime protocol, session driver, and eleven-phase trace. It
// deliberately has no package dependency—not even Cog—so a comparison runtime
// can resolve and compile the identical workload without resolving another
// state-management implementation.

/// The build shape every Storefront workload and runtime target uses.
///
/// Each runtime package carries a byte-identical copy because SwiftPM manifests
/// cannot import one another. The verification package checks the copies as
/// source text so a comparison cannot silently measure different compiler
/// isolation or language settings.
let storefrontSwiftSettings: [SwiftSetting] = [
  .swiftLanguageMode(.v6),
  .defaultIsolation(MainActor.self),
  .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("MemberImportVisibility"),
  .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
  name: "cog-storefront-workload",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
  ],
  products: [
    .library(name: "StorefrontWorkload", targets: ["StorefrontWorkload"])
  ],
  dependencies: [],
  targets: [
    .target(
      name: "StorefrontWorkload",
      dependencies: [],
      swiftSettings: storefrontSwiftSettings
    ),
    .testTarget(
      name: "StorefrontWorkloadTests",
      dependencies: ["StorefrontWorkload"],
      swiftSettings: storefrontSwiftSettings
    ),
  ]
)
