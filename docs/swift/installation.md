# Install Cog for Swift

Cog requires iOS 17 or macOS 14, Swift tools 6.2, and a full Xcode. Releases
are tested with Xcode 26.6 and Swift 6.3.3.

## Add Cog in Xcode

1. Choose **File ▸ Add Package Dependencies**.
2. Enter `https://github.com/skeswa/cog.git`.
3. Choose **Up to Next Minor Version**. Before 1.0, a minor release may
   include listed breaking changes; patch releases do not.
4. Add the `Cog` product to the app target.
5. Add `CogTesting` to each test or preview-support target that creates an
   isolated runtime.

Cog resolves with no dependencies of its own. Once Xcode finishes resolving
the package, `import Cog` should build in the app target.

## Add Cog to a Swift package

The complete manifest below creates one package target and one test target.
Rename `Forecast` to match your module.

<!-- x-release-please-start-version -->

```swift [Package.swift]
// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "Forecast",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
  ],
  dependencies: [
    .package(
      url: "https://github.com/skeswa/cog.git",
      .upToNextMinor(from: "0.6.1")
    )
  ],
  targets: [
    .target(
      name: "Forecast",
      dependencies: [
        .product(name: "Cog", package: "cog")
      ]
    ),
    .testTarget(
      name: "ForecastTests",
      dependencies: [
        "Forecast",
        .product(name: "CogTesting", package: "cog"),
      ]
    ),
  ]
)
```

<!-- x-release-please-end -->

Use `Cog` in production targets. `CogTesting` depends on and re-exports `Cog`,
but belongs only in tests and preview support.

## Continue

[Build the quick-start app](./getting-started.md) to declare a value, put it on
screen, change it from a button, and test it with an isolated runtime.

For the optional `CompactArena` binary-size trade-off, see
[Add Cog to a Swift app](https://github.com/skeswa/cog/blob/main/README.md#add-cog-to-a-swift-app).
