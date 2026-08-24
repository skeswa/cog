// swift-tools-version: 6.3

import PackageDescription

/// The step-1 confirmation probe for swift-state-graph 0.28.0.
///
/// This package exists to answer, empirically, the four questions the
/// four-runtime Storefront specification marks "guessed" about
/// swift-state-graph: whether `Computed` memoizes, whether a batching or
/// transaction API coalesces N source writes into one downstream
/// recomputation, how a keyed or dynamic node collection behaves, and what the
/// definite settlement signal after a write actually is.
///
/// It is a package of its own, nested under `swift/Benchmarks/Macro/Storefront/StateGraph/`,
/// because it must resolve swift-state-graph while the port package that will
/// eventually sit beside it does not exist yet. Nothing else in the repository
/// depends on it, and nothing it resolves reaches the root package.
let package = Package(
  name: "sgprobe",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(url: "https://github.com/VergeGroup/swift-state-graph", exact: "0.28.0")
  ],
  targets: [
    .executableTarget(
      name: "sgprobe",
      dependencies: [
        .product(name: "StateGraph", package: "swift-state-graph")
      ],
      path: "Sources/sgprobe"
    )
  ],
  swiftLanguageModes: [.v6]
)
