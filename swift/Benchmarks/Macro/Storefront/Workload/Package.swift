// swift-tools-version:6.2

import PackageDescription

// A third package of its own, and this file is the whole reason.
//
// The Storefront workload is shared by two very different consumers: the
// headless benchmark executable in the `cog-benchmarks` package, and the
// SwiftUI benchmark application in `Apps/Cog`. Neither may drag the other's
// dependencies behind it.
//
// This directory sits *inside* `swift/Benchmarks/`, the `cog-benchmarks`
// package directory. That is a **filesystem fact, not a dependency fact**, and
// it must never be read as an invitation to merge the two. The argument for
// separation was always about the *package*, never about which corner of the
// tree the sources sat in.
//
// The argument: SwiftPM hands a package's dependencies to everyone who resolves
// it, so making this workload a target of `cog-benchmarks` — or giving a
// `cog-benchmarks` target a `path:` that reaches in here — would break the
// SwiftUI benchmark applications under `Apps/`. That package depends on the
// ordo-one benchmark harness, its malloc interposer, and swift-state-graph, and
// an iOS application target that consumed a library product from it would
// resolve all three. Putting the workload in the root package is worse still —
// the root resolves with **no** dependencies at all, which is a shipped
// property of the library rather than a tidiness preference, and a
// benchmark-only workload has no business inside the module a consumer imports.
//
// The sibling `Runtimes` and `StateGraph` directories are nested for the same
// reason and carry the same prohibition: three separate packages that happen to
// live under a fourth package's directory.
//
// So the dependency arrows all point one way, and this package sits at the
// bottom of the benchmark-only half of them:
//
//                            cog (root, zero dependencies)
//                                 ^
//                                 |
//      ┌──────────────────────────┴───────────────────────────────────────┐
//      │  cog-storefront   —   swift/Benchmarks/Macro/Storefront/Workload │
//      │                                                                  │
//      │   StorefrontWorkload  ......  zero dependencies                  │
//      │        ^        ^        ^        ^                              │
//      │        |        |        |        |                              │
//      │   CogStorefront │        │        │                              │
//      │   (Cog, CogTesting)      │        │                              │
//      └────────^────────┼────────┼────────┼──────────────────────────────┘
//               |        |        |        |
//               |        |        |        └──── cog-storefront-state-graph
//               |        |        |               swift/Benchmarks/Macro/Storefront/StateGraph
//               |        |        |                 └── swift-state-graph 0.28.0
//               |        |        |
//               |        |        └──────────── cog-storefront-runtimes
//               |        |                       swift/Benchmarks/Macro/Storefront/Runtimes
//               |        |                         StorefrontObservationMemo
//               |        └───────────────────── cog-storefront-runtimes
//               |                                 StorefrontObservationRaw
//               |
//               └── Storefront.app (Xcode, iOS)
//                    swift/Benchmarks/Macro/Storefront/Apps/Cog
//                    [+ sibling comparison apps under Apps/, later phase]
//
//      cog-benchmarks        swift/Benchmarks
//      (harness, malloc interposer, swift-state-graph)
//           │
//           ├──> cog                        (path ../..)
//           ├──> cog-storefront             (path Macro/Storefront/Workload)
//           ├──> cog-storefront-runtimes    (path Macro/Storefront/Runtimes)
//           └──> cog-storefront-state-graph (path Macro/Storefront/StateGraph)
//
//      Three of those boxes sit *inside* the fourth box's directory. They are still
//      four packages: the nesting is a filesystem fact, and the arrows are the
//      dependency facts.
//
// Every arrow points down or right. Nothing points back into the root, and
// nothing an iOS application target links reaches the harness, the interposer,
// or swift-state-graph unless that specific application is the state-graph
// comparison app.
//
// This package therefore depends on the root by path and on nothing else. It
// is deliberately dependency-free for the same reason the root is: an iOS
// application must be able to link it without resolving a benchmark harness.
//
// The path dependency is a path and never a version, for the reason
// `swift/Benchmarks/README.md` records: a measurement resolved from a tag is a
// statement about a turn that is not the one being changed.

/// The one build shape every Storefront target uses.
///
/// Hoisted to a constant rather than repeated because a comparison whose
/// runtimes were compiled under different isolation or language-mode settings
/// would be measuring the settings. Any change here changes every runtime at
/// once, which is the property that makes the comparison legible.
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
  // iOS carries the SwiftUI benchmark application; macOS carries the headless
  // benchmark executable and this package's own correctness tests. Both floors
  // match the root package exactly, so the workload cannot accidentally depend
  // on a runtime API Cog itself refuses.
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
  ],
  products: [
    // The runtime-neutral half: model, fixtures, kernels, pricing, the
    // scripted service, the shadow model, the sink, the checkpoint
    // vocabulary, the `StorefrontRuntime` protocol, the generic eleven-phase
    // trace and its session driver, and the completion signal a port fires
    // when it has decided about one asynchronous result. It depends on nothing
    // at all — not even Cog — which is what lets a port with no Cog in it run
    // the identical script.
    .library(name: "StorefrontWorkload", targets: ["StorefrontWorkload"]),
    // Not API, and never will be. It carries no underscore — unlike
    // `_CogScenarios` in the root package — because nothing here is reachable
    // from a Cog consumer at all: this package is not a dependency of the
    // library, so an application developer never sees the product to be tempted
    // by it. It exists so the headless benchmark and the SwiftUI benchmark
    // application can share one workload.
    .library(name: "CogStorefront", targets: ["CogStorefront"]),
  ],
  dependencies: [
    // Five components up: `Workload` -> `Storefront` -> `Macro` ->
    // `Benchmarks` -> `swift` -> the repository root, which is the root
    // package's directory.
    .package(path: "../../../../..")
  ],
  targets: [
    // Deliberately `dependencies: []`, and that emptiness is load-bearing
    // rather than incidental: it is what makes it possible for a runtime with
    // no Cog in it to run the identical workload, and it is mechanically
    // checkable with `swift package describe --type json`.
    .target(
      name: "StorefrontWorkload",
      dependencies: [],
      path: "Sources/StorefrontWorkload",
      swiftSettings: storefrontSwiftSettings
    ),
    // The Cog half, and only that: the state declarations, the domain verbs,
    // the assembly mechanism, and the one `StorefrontRuntime` adapter through
    // which the neutral driver runs its trace against Cog.
    .target(
      name: "CogStorefront",
      dependencies: [
        "StorefrontWorkload",
        .product(name: "Cog", package: "cog"),
        .product(name: "CogTesting", package: "cog"),
      ],
      path: "Sources/CogStorefront",
      swiftSettings: storefrontSwiftSettings
    ),
    .testTarget(
      name: "StorefrontWorkloadTests",
      dependencies: ["StorefrontWorkload"],
      path: "Tests/StorefrontWorkloadTests",
      swiftSettings: storefrontSwiftSettings
    ),
    .testTarget(
      name: "CogStorefrontTests",
      dependencies: [
        "CogStorefront",
        "StorefrontWorkload",
        .product(name: "Cog", package: "cog"),
        .product(name: "CogTesting", package: "cog"),
      ],
      path: "Tests/CogStorefrontTests",
      swiftSettings: storefrontSwiftSettings
    ),
  ]
)
