// swift-tools-version:6.2

import PackageDescription

// A package of its own, and this file is the whole reason.
//
// This package holds the swift-state-graph port of the Storefront
// macrobenchmark: the fourth runtime, running the identical eleven-phase
// interaction trace from `StorefrontWorkload` so that its numbers are comparable
// with Cog's rather than merely adjacent to them.
//
// It is separate from `cog-storefront-runtimes`, which holds the two
// `@Observable` ports, for one reason: SwiftPM hands a package's dependencies to
// everyone who resolves it. If the state-graph port shared a package with the
// `@Observable` ports, an `@Observable` comparison application would resolve
// swift-state-graph and its macro toolchain along with the port it actually
// wanted. That is the identical mistake
// `swift/Benchmarks/Macro/Storefront/Workload/README.md` already documents one
// level up about the `cog-benchmarks` *package*, and the answer is the same
// one: give the dependency a package of its own so it reaches only the consumers
// that ask for it.
//
// This directory sits *inside* `swift/Benchmarks/`, the `cog-benchmarks`
// package directory. That is a **filesystem fact, not a dependency fact**, and
// it must never be read as an invitation to merge the two. Merging would break
// the iOS applications: a comparison application under `Apps/` that linked this
// port from a merged package would resolve the benchmark harness and the malloc
// interposer along with swift-state-graph. Nor may a `cog-benchmarks` target
// reach in here with a `path:`; it consumes this port through a path
// *dependency*, the same way any other package would.
//
// It is separate from `cog-storefront` for that reason and for a second: that
// package is the worked large-app Cog example and must stay that, and CogLint
// runs its sources under the Cog application ruleset, which has no business
// being applied to a port that contains no Cog symbol at all.
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
// swift-state-graph is pinned `exact` rather than to a range, matching
// `swift/Benchmarks/Package.swift`: the port is written against the source of
// one exact release, and a comparison that silently resolved a different one
// would be reporting a number about code nobody read. `Package.resolved` is
// committed here for the same reason it is committed there.
//
// The workload dependency is a path and never a version, for the reason
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
  name: "cog-storefront-state-graph",
  // The same floors as `cog-storefront` and the root package: iOS carries the
  // SwiftUI comparison application, macOS carries the headless benchmark cuts
  // and this package's own correctness tests.
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
  ],
  products: [
    .library(name: "StorefrontStateGraph", targets: ["StorefrontStateGraph"])
  ],
  dependencies: [
    // The sibling workload package. SwiftPM derives a path dependency's
    // identity from the last path component, not from the manifest `name:`, so
    // this package's identity is `Workload` even though it is named
    // `cog-storefront`; that is the spelling every `package:` below uses.
    .package(path: "../Workload"),
    // Comparison-only prior art, pinned at the exact release whose source the
    // port was written and probed against. This dependency belongs only to this
    // package; adding it anywhere a Cog consumer resolves would make that
    // consumer resolve StateGraph and its macro toolchain.
    .package(
      url: "https://github.com/VergeGroup/swift-state-graph",
      exact: "0.28.0"
    ),
  ],
  targets: [
    .target(
      name: "StorefrontStateGraph",
      dependencies: [
        .product(name: "StorefrontWorkload", package: "Workload"),
        .product(name: "StateGraph", package: "swift-state-graph"),
      ],
      // Every target below states an explicit `path:` under `Sources/` or
      // `Tests/`, and that is what keeps `Probe/` out of the build. `Probe/` is
      // a nested SwiftPM package of its own — the throwaway executable that
      // confirmed 0.28.0's memoization, transaction, keyed-node, and settlement
      // behavior before this port was written, with its findings recorded in
      // `API-NOTES.md`. It lives here rather than beside it because it had to
      // resolve swift-state-graph before this package existed. SwiftPM never
      // walks it: it is outside every target root, so it is neither compiled
      // into this target nor reported as an unhandled file, and its own
      // `Package.swift` and `Package.resolved` stay its own business.
      path: "Sources/StorefrontStateGraph",
      swiftSettings: storefrontSwiftSettings
    ),
    .testTarget(
      name: "StorefrontStateGraphTests",
      dependencies: [
        "StorefrontStateGraph",
        .product(name: "StorefrontWorkload", package: "Workload"),
        // The memoization suite builds its own two-node graphs through the
        // port's own node constructors, so it has to be able to read a
        // `Computed` and to build the deliberately non-memoizing control that
        // proves the instrument can tell the two overloads apart. That is the
        // only reason a test target here names StateGraph; the trace and
        // descriptor suites hold the port to its public contract alone.
        .product(name: "StateGraph", package: "swift-state-graph"),
      ],
      path: "Tests/StorefrontStateGraphTests",
      swiftSettings: storefrontSwiftSettings
    ),
  ]
)
