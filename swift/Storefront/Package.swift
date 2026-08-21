// swift-tools-version:6.2

import PackageDescription

// A third package of its own, and this file is the whole reason.
//
// The Storefront workload is shared by two very different consumers: the
// headless benchmark executable in `swift/Benchmarks`, and the SwiftUI
// benchmark application in `swift/Examples/Storefront`. Neither may drag the
// other's dependencies behind it.
//
// Putting the workload in `swift/Benchmarks` would have been the obvious
// place, and it is the wrong one: that package depends on the benchmark
// harness, its malloc interposer, and swift-state-graph, and an iOS
// application target that consumed a library product from it would resolve all
// three. Putting it in the root package is worse still — the root resolves
// with **no** dependencies at all, which is a shipped property of the library
// rather than a tidiness preference, and a benchmark-only workload has no
// business inside the module a consumer imports.
//
// So the dependency arrows all point one way and this package sits at the
// bottom of the benchmark-only half of them:
//
//     cog (root, zero dependencies)
//       ^                    ^
//       |                    |
//     cog-storefront   <---- cog-benchmarks (harness, interposer, state-graph)
//       ^
//       |
//     Storefront.app (Xcode, iOS)
//
// This package therefore depends on the root by path and on nothing else. It
// is deliberately dependency-free for the same reason the root is: an iOS
// application must be able to link it without resolving a benchmark harness.
//
// The path dependency is a path and never a version, for the reason
// `swift/Benchmarks/README.md` records: a measurement resolved from a tag is a
// statement about a commit that is not the one being changed.

let package = Package(
  name: "cog-storefront",
  // iOS carries the SwiftUI benchmark application; macOS carries the headless
  // benchmark executable and this package's own correctness tests. Both floors
  // match the root package exactly, so the workload cannot accidentally depend
  // on a runtime API Cog itself refuses.
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
  ],
  products: [
    // Not API, and never will be. It carries no underscore — unlike
    // `_CogScenarios` in the root package — because nothing here is reachable
    // from a Cog consumer at all: this package is not a dependency of the
    // library, so an application developer never sees the product to be tempted
    // by it. It exists so the headless benchmark and the SwiftUI benchmark
    // application can share one workload.
    .library(name: "CogStorefront", targets: ["CogStorefront"])
  ],
  dependencies: [
    .package(path: "../..")
  ],
  targets: [
    .target(
      name: "CogStorefront",
      dependencies: [
        .product(name: "Cog", package: "cog"),
        .product(name: "CogTesting", package: "cog"),
      ],
      path: "Sources/CogStorefront",
      // The same shape the root library builds with. This target is
      // application code — declarations, ops, mechanisms, and views' worth of
      // presentation mapping — so it lives on the same actor and under the
      // same upcoming features the code it imitates does.
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .defaultIsolation(MainActor.self),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
        .enableUpcomingFeature("ExistentialAny"),
        .enableUpcomingFeature("MemberImportVisibility"),
        .enableUpcomingFeature("InternalImportsByDefault"),
      ]
    ),
    .testTarget(
      name: "CogStorefrontTests",
      dependencies: [
        "CogStorefront",
        .product(name: "Cog", package: "cog"),
        .product(name: "CogTesting", package: "cog"),
      ],
      path: "Tests/CogStorefrontTests",
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .defaultIsolation(MainActor.self),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
        .enableUpcomingFeature("ExistentialAny"),
        .enableUpcomingFeature("MemberImportVisibility"),
        .enableUpcomingFeature("InternalImportsByDefault"),
      ]
    ),
  ]
)
