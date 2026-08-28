// swift-tools-version: 6.3

import PackageDescription

/// The step-1 confirmation probe for swift-state-graph 0.28.0.
///
/// Confirms four swift-state-graph behaviors used by Storefront: `Computed`
/// memoization, batched writes, dynamic keyed nodes, and post-write settlement.
///
/// This nested package resolves swift-state-graph without adding it to the root
/// package. Nothing else depends on the probe.
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
