// swift-tools-version:6.2

import PackageDescription

// A package of its own, and this file is the whole reason.
//
// This package holds the two plain-Swift comparison runtimes for the Storefront
// macrobenchmark: `StorefrontObservationRaw`, which recomputes on every read and
// is the floor the other three are measured against, and
// `StorefrontObservationMemo`, which is honest hand-written memoization over the
// same `@Observable` primitives. Both run the identical eleven-phase interaction
// trace from `StorefrontWorkload`, so their numbers are comparable with Cog's
// rather than merely adjacent to them.
//
// This directory sits *inside* `swift/Benchmarks/`, the `cog-benchmarks`
// package directory. That is a **filesystem fact, not a dependency fact**, and
// it must never be read as an invitation to merge the two. Merging would break
// the iOS applications: `cog-benchmarks` depends on the ordo-one benchmark
// harness, its malloc interposer, and swift-state-graph, and SwiftPM hands a
// package's dependencies to everyone who resolves it, so an `@Observable`
// comparison application under `Apps/` that linked one of these ports from a
// merged package would resolve all three. Nor may a `cog-benchmarks` target
// reach in here with a `path:`; it consumes these ports through a path
// *dependency*, the same way any other package would, and that is the property
// to preserve.
//
// Neither port contains a single Cog symbol, and that is exactly why they are
// not in `cog-storefront` either. Two reasons, in order of weight.
//
// First, CogLint runs `swift/Benchmarks/Macro/Storefront/Workload/Sources`
// under `--target-role production`, which applies the Cog *application*
// ruleset — `manual-cog-underscore` and the `Cog`/`Cogs` suffix conventions —
// to everything under that path. A target whose entire point is to contain no
// Cog would be linted as Cog application code, and the fix for that must never
// be to weaken a rule the library ships to real consumers.
//
// Second, `cog-storefront` is the package an application developer may one day
// be pointed at as the worked large-app example. It should contain the Cog way
// of building this app, not three alternatives to it.
//
// The ports are two separate targets rather than one target with two types, and
// that separation is a fairness mechanism rather than tidiness: it makes it a
// compile error for the raw port to reach the memo port's cache, which is the
// single most likely way this comparison could quietly become dishonest.
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
// This package therefore depends on `../Workload` by path and on **nothing
// else**. The emptiness beyond that one path dependency is load-bearing: an
// `@Observable` comparison application must be able to link a port here without
// resolving swift-state-graph and its macro toolchain, which is precisely what
// would happen if the state-graph port shared this package. SwiftPM hands a
// package's dependencies to everyone who resolves it.
//
// The path dependency is a path and never a version, for the reason
// `swift/Benchmarks/README.md` records: a measurement resolved from a tag is a
// statement about a turn that is not the one being changed.

/// The one build shape every Storefront target uses.
///
/// Copied verbatim from `swift/Benchmarks/Macro/Storefront/Workload/Package.swift`, and it must stay
/// byte-identical to it: a comparison whose runtimes were compiled under
/// different isolation or language-mode settings would be measuring the
/// settings rather than the runtimes. It is copied rather than shared because
/// SwiftPM manifests cannot import one another, and `StorefrontWorkloadTests`
/// gains an assertion that the three copies agree as the ports land.
let storefrontSwiftSettings: [SwiftSetting] = [
  .swiftLanguageMode(.v6),
  .defaultIsolation(MainActor.self),
  .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("MemberImportVisibility"),
  .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
  name: "cog-storefront-runtimes",
  // The same floors as `cog-storefront` and the root package: iOS carries the
  // SwiftUI comparison applications, macOS carries the headless benchmark cuts
  // and this package's own correctness tests.
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
  ],
  products: [
    // The floor: recompute on every read, no caching anywhere. Its numbers are
    // what a hand-written `@Observable` app costs when nobody has optimized it.
    .library(name: "StorefrontObservationRaw", targets: ["StorefrontObservationRaw"]),
    // Honest hand-written memoization over the same primitives: what a careful
    // team would actually write, and the cost of writing it.
    .library(name: "StorefrontObservationMemo", targets: ["StorefrontObservationMemo"]),
  ],
  dependencies: [
    // The sibling workload package. SwiftPM derives a path dependency's
    // identity from the last path component, not from the manifest `name:`, so
    // this package's identity is `Workload` even though it is named
    // `cog-storefront`; that is the spelling every `package:` below uses.
    .package(path: "../Workload")
  ],
  targets: [
    .target(
      name: "StorefrontObservationRaw",
      dependencies: [
        .product(name: "StorefrontWorkload", package: "Workload")
      ],
      path: "Sources/StorefrontObservationRaw",
      swiftSettings: storefrontSwiftSettings
    ),
    .target(
      name: "StorefrontObservationMemo",
      dependencies: [
        .product(name: "StorefrontWorkload", package: "Workload")
      ],
      path: "Sources/StorefrontObservationMemo",
      swiftSettings: storefrontSwiftSettings
    ),
    // One test target for both ports, because most of what these tests assert
    // is that the two ports and the shared shadow model agree; splitting them
    // would make the cross-port agreement suite pick a home arbitrarily.
    .testTarget(
      name: "StorefrontRuntimesTests",
      dependencies: [
        "StorefrontObservationRaw",
        "StorefrontObservationMemo",
        .product(name: "StorefrontWorkload", package: "Workload"),
      ],
      path: "Tests/StorefrontRuntimesTests",
      swiftSettings: storefrontSwiftSettings
    ),
  ]
)
