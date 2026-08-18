// swift-tools-version:6.2

import PackageDescription

// A package of its own, deliberately, and this file is the whole reason.
//
// Benchmarking needs a harness, an allocator backend, and a baseline-checking
// CLI. None of that belongs in the dependency graph a consumer resolves:
// SwiftPM gives a package's dependencies to everyone who resolves it, so a
// benchmark dependency added to the root manifest would reach every app that
// adds Cog. The root package resolves with **no** dependencies at all
// (swift-docc-plugin is environment-gated behind `COG_DOCC=1` for the same
// reason), and keeping that true is a shipped property rather than a tidiness
// preference.
//
// The relationship only runs one way: this package depends on the root by
// path, and nothing in the root references this directory. `M5-05a` proved
// that by describing both manifests and reading the root's dependency graph.

let package = Package(
  name: "cog-benchmarks",
  // Host-only. Benchmarks measure the graph, which is platform-independent
  // MainActor code, so there is nothing an iOS destination would add beyond
  // simulator noise.
  platforms: [.macOS(.v14)],
  dependencies: [
    // Cog itself, by local path — never a version. Benchmarks measure the
    // working tree, so resolving Cog from a tag would make every measurement a
    // statement about a commit that is not the one being changed.
    .package(path: "../.."),
    // Comparison-only prior art, pinned at the exact release whose source the
    // adapter was written against. This dependency belongs only to the
    // separate benchmark package; adding it to the root would make Cog
    // consumers resolve StateGraph and its macro toolchain.
    .package(
      url: "https://github.com/VergeGroup/swift-state-graph",
      exact: "0.28.0"
    ),
    // The harness, pinned exactly rather than to a range, on upstream's own
    // words: the `.benchmarkBaselines` representation "is not stable and is not
    // viewed as public API and may break over time", and malloc metrics are not
    // comparable across backends. A recorded baseline is a statement about one
    // harness version, so an upgrade is a reviewed event that arrives together
    // with re-baselining rather than something a resolve can do behind the
    // repository's back. `M5-05ba` records the full reasoning, including why
    // 1.35.0 is the floor and why the URL is `benchmark` rather than the old
    // `package-benchmark`.
    .package(url: "https://github.com/ordo-one/benchmark", exact: "1.36.2"),
  ],
  targets: [
    // Benchmark sources must live in a directory literally named `Benchmarks`
    // at the package root — upstream's discovery rule, which is why the path
    // below reads `Benchmarks/…` inside a directory already called
    // `Benchmarks`.
    .executableTarget(
      name: "CogGraph",
      dependencies: [
        .product(name: "Benchmark", package: "benchmark"),
        .product(name: "Cog", package: "cog"),
        .product(name: "CogTesting", package: "cog"),
        .product(name: "StateGraph", package: "swift-state-graph"),
        // The shared scenario graphs. Sharing them with `CogScenarioTests` is
        // the point: a run-count assertion and a timing measurement that
        // disagreed about which graph they ran would make both meaningless.
        .product(name: "_CogScenarios", package: "cog"),
      ],
      path: "Benchmarks/CogGraph",
      // Deliberately *not* `.defaultIsolation(MainActor.self)`. Upstream's
      // Swift 6 contract is a nonisolated `@Sendable` `benchmarks` closure, and
      // the plugin-generated entry point calls it from a nonisolated context.
      // MainActor code reaches the graph through the isolated harness type in
      // the target instead, which is the shim `M5-05bb` proved sufficient.
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .enableUpcomingFeature("ExistentialAny"),
        .enableUpcomingFeature("MemberImportVisibility"),
        .enableUpcomingFeature("InternalImportsByDefault"),
      ],
      plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]
    )
  ]
)
