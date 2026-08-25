// swift-tools-version:6.2
import PackageDescription

let package = Package(
  name: "CogProfile",
  platforms: [.macOS(.v14)],
  dependencies: [.package(path: "../../../../..")],
  targets: [
    .executableTarget(
      name: "CogProfile",
      dependencies: [
        .product(name: "Cog", package: "cog"),
        .product(name: "CogTesting", package: "cog"),
      ],
      path: "Sources/CogProfile",
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .defaultIsolation(MainActor.self),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
        .enableUpcomingFeature("ExistentialAny"),
        .enableUpcomingFeature("MemberImportVisibility"),
        .enableUpcomingFeature("InternalImportsByDefault"),
      ]
    )
  ]
)
