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

/// The build shape the cross-runtime agreement suite is compiled with.
///
/// Byte-for-byte the `storefrontSwiftSettings` array the three Storefront
/// packages carry, and for the same reason: a suite that compared four runtimes
/// while itself compiled under a different isolation default or language mode
/// would be comparing them through a lens none of them was built with. The
/// agreement suite drives every runtime through the same generic driver, so it
/// has to speak the same dialect that driver was compiled in — in particular
/// `NonisolatedNonsendingByDefault`, which decides where an `async` call taken
/// across the module boundary resumes.
///
/// It is spelled out here rather than named `storefrontSwiftSettings` on
/// purpose. `StorefrontBuildShapeTests` compares exactly three manifests —
/// `swift/Benchmarks/Macro/Storefront/Workload`, `swift/Benchmarks/Macro/Storefront/Runtimes`, and
/// `swift/Benchmarks/Macro/Storefront/StateGraph` — because those three compile the runtimes being
/// measured. This package compiles no runtime; it only drives them. Borrowing
/// the parity-checked name would imply a guarantee that no test makes.
let agreementSwiftSettings: [SwiftSetting] = [
  .swiftLanguageMode(.v6),
  .defaultIsolation(MainActor.self),
  .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("MemberImportVisibility"),
  .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
  name: "cog-benchmarks",
  // Host-only. Benchmarks measure the graph, which is platform-independent
  // MainActor code, so there is nothing an iOS destination would add beyond
  // simulator noise.
  platforms: [.macOS(.v14)],
  traits: [
    // Mirrors the root package's public binary-size trade so a benchmark run
    // can compare the exact configuration applications select.
    .trait(name: "CompactArena")
  ],
  dependencies: [
    // Cog itself, by local path — never a version. Benchmarks measure the
    // working tree, so resolving Cog from a tag would make every measurement a
    // statement about a turn that is not the one being changed.
    .package(
      path: "../..",
      traits: [
        .trait(name: "CompactArena", condition: .when(traits: ["CompactArena"]))
      ]
    ),
    // The shared Storefront macrobenchmark workload, also by local path. It
    // sits under this package's own directory, but it is a *package* of its own
    // rather than a target of this one because the SwiftUI benchmark
    // application consumes the same workload, and an iOS application target
    // that depended on *this* package would resolve the benchmark harness, the
    // malloc interposer, and swift-state-graph along with it. Nesting is a
    // filesystem fact, not a dependency fact; `Macro/Storefront/Workload` is
    // deliberately dependency-free for that reason. So the three packages under
    // `Macro/` are reached the way any other package is — by path *dependency*,
    // right here. Never fold one of them into a target of this package, and
    // never give a target of this package a `path:` that reaches into `Macro/`:
    // either move would break the iOS applications under
    // `Macro/Storefront/Apps/`.
    .package(path: "Macro/Storefront/Workload"),
    // The two plain-Swift comparison runtimes. A package of their own because
    // `cog-storefront` is the Cog example and must stay that, and because an
    // `@Observable` comparison application must not resolve swift-state-graph.
    // This package is the only place all four runtimes may coexist, which is
    // what makes the cross-runtime agreement suite below possible at all.
    .package(path: "Macro/Storefront/Runtimes"),
    // The swift-state-graph port. A package of its own for the reason
    // `Macro/Storefront/Workload/README.md` records: a package dependency
    // reaches everyone who resolves the package.
    .package(path: "Macro/Storefront/StateGraph"),
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
    // A benchmark target's **immediate parent directory** must be literally
    // named `Benchmarks`. Not "a directory named `Benchmarks` at the package
    // root" — that was the old wording here and it is wrong. Upstream tests the
    // immediate parent and nothing else, at three call sites in the pinned
    // harness 1.36.2 under `.build/checkouts/benchmark`, each of the form
    // `<target>.directory.removingLastComponent().lastComponent == "Benchmarks"`:
    //
    //   - `Plugins/BenchmarkPlugin/BenchmarkSupportPlugin.swift:27`
    //   - `Plugins/BenchmarkCommandPlugin/BenchmarkCommandPlugin.swift:488`
    //   - `Plugins/BenchmarkCommandPlugin/ArgumentExtractor+Extensions.swift:42`
    //
    // The consequence is worth stating plainly, because it is silent. A
    // benchmark target whose parent directory is named anything else is simply
    // not discovered: the plugin generates no entry point for it, and
    // `swift package benchmark` reports nothing to run — which is CI going
    // green having measured nothing. That failure mode is why this rule is
    // written down here rather than left to be re-derived from plugin source.
    //
    // So the doubled `swift/Benchmarks/Benchmarks/CogGraph` path is upstream's
    // requirement crossed with our own directory name: `swift/Benchmarks` is
    // where this package lives, and the inner `Benchmarks` is the name the
    // discovery rule demands of a benchmark target's parent.
    //
    // Renaming was considered and rejected, and it is settled — the check is on
    // the immediate parent only, so `Benchmarks/Micro` would have been legal and
    // a bare `Micro/` never was, which means the rename buys a nicer name at the
    // cost of nothing but churn. `CogGraph` is the target name and it appears in
    // every committed threshold filename
    // (`Thresholds/CogGraph.perf-01-steady-turn.p90.json`) and in every
    // documented `mise run bench --filter` invocation, so renaming it would
    // rewrite gates and runbooks to no measurable end.
    //
    // `Macro/` next door is asymmetric on purpose and the asymmetry is honest:
    // it holds separate SwiftPM packages, which are not benchmark targets at
    // all, so the discovery rule does not reach them.
    .executableTarget(
      name: "CogGraph",
      dependencies: [
        .product(name: "Benchmark", package: "benchmark"),
        .product(name: "Cog", package: "cog"),
        .product(name: "CogTesting", package: "cog"),
        .product(name: "StateGraph", package: "swift-state-graph"),
        // The Storefront macrobenchmark's Cog port: its state declarations,
        // domain verbs, assembly mechanism, and the `StorefrontRuntime` adapter
        // the neutral trace drives — the same ones the SwiftUI benchmark
        // application drives. The package *identity* is `Workload`, the last
        // component of its path, even though its manifest is named
        // `cog-storefront`; SwiftPM derives identity from the location, not the
        // name, exactly as it does for `cog` itself.
        .product(name: "CogStorefront", package: "Workload"),
        // The runtime-neutral half of that same workload: the model, fixtures,
        // kernels, pricing ladder, scripted service, shadow model, sink,
        // `StorefrontRuntime` protocol, and the generic session driver and
        // eleven-phase trace every runtime is measured through.
        // Named explicitly rather than taken transitively because
        // `MemberImportVisibility` is enabled here: a client sees a module's
        // members only when it imports that module directly.
        .product(name: "StorefrontWorkload", package: "Workload"),
        // The three comparison runtimes, so a `perf-16` cut can measure each of
        // them through the same generic driver. Their package *identities* are
        // `Runtimes` and `StateGraph`, the last components of their paths, even
        // though their manifests are named `cog-storefront-runtimes` and
        // `cog-storefront-state-graph`.
        .product(name: "StorefrontObservationRaw", package: "Runtimes"),
        .product(name: "StorefrontObservationMemo", package: "Runtimes"),
        .product(name: "StorefrontStateGraph", package: "StateGraph"),
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
    ),
    // The cross-runtime agreement suite, and it lives here because there is
    // nowhere else it could.
    //
    // Each runtime's own package proves that runtime agrees with the shared
    // shadow, which is a transitive argument that the four agree with each
    // other. This suite makes that argument directly instead, by linking all
    // four and comparing their settled answers value for value. It can only do
    // that here: `cog-storefront` cannot see the ports, and the two port
    // packages cannot see each other — deliberately, since target separation is
    // the mechanism that stops one port from reaching into another's cache. This
    // package already depends on all four, so it is the one place where the four
    // coexist without weakening that separation.
    //
    // A test target rather than a benchmark cut, because it asserts rather than
    // measures: it is the gate every `perf-16` number rests on, and a fast
    // number from a runtime that computed a different answer would be worse than
    // no number at all. It depends on the four runtime products and on the
    // neutral workload, and on nothing from `CogGraph` — the harness has no
    // business in a correctness proof.
    .testTarget(
      name: "StorefrontAgreementTests",
      dependencies: [
        .product(name: "CogStorefront", package: "Workload"),
        .product(name: "StorefrontWorkload", package: "Workload"),
        .product(name: "StorefrontObservationRaw", package: "Runtimes"),
        .product(name: "StorefrontObservationMemo", package: "Runtimes"),
        .product(name: "StorefrontStateGraph", package: "StateGraph"),
      ],
      path: "Tests/StorefrontAgreementTests",
      swiftSettings: agreementSwiftSettings
    ),
  ]
)
