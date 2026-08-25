import Foundation
import Testing

/// Build-shape parity across the four packages the comparison is compiled in.
///
/// The workload is one script run by four runtimes, but those runtimes are
/// spread over four SwiftPM packages — the dependency-free workload, the Cog
/// port, the two `@Observable` ports, and the swift-state-graph port. Each
/// package carries its own copy of the compiler settings every target is built
/// with, and SwiftPM manifests cannot import one another, so this suite makes
/// the copies agree.
///
/// The agreement is not cosmetic. A comparison whose runtimes were compiled
/// under different isolation defaults, language modes, or upcoming features
/// would be measuring the settings rather than the runtimes: default MainActor
/// isolation alone changes what a call costs. Both sibling manifests say in
/// prose that this assertion is what keeps them honest; this is that assertion.
///
/// It compares the settings blocks as *text*, byte for byte, rather than as a
/// parsed set. A test target cannot evaluate a manifest, and text is the
/// stronger check anyway: reordering, respelling, or commenting a setting
/// differently in one package is exactly the kind of divergence that would
/// otherwise be argued away as equivalent.
@Suite("Storefront build-shape parity")
struct StorefrontBuildShapeTests {
  /// The Storefront suite directory, derived from this file's path.
  ///
  /// A `#filePath` walk rather than a bundle resource, for the reason the
  /// declaration census walks one too: a manifest is source text, not a build
  /// product, and the manifests being compared are in *sibling* packages that
  /// this package's build never copies anything out of. Each level is named so
  /// that moving this file is a visible edit rather than a silent miscount, and
  /// ``manifestText(forPackage:)`` refuses a missing file, which is what makes a
  /// wrong answer here fail loudly instead of comparing nothing.
  static var macrobenchmarkDirectory: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // Tests/StorefrontAgreementTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // Verification, the package root
      .deletingLastPathComponent()  // Storefront, the suite root
  }

  /// Relative package paths whose settings must agree.
  ///
  /// Arrays of components keep filesystem traversal explicit without encoding
  /// platform separators into a path string.
  static let comparedPackagePaths = [
    ["Workload"],
    ["Runtimes", "CogRuntime"],
    ["Runtimes", "Observation"],
    ["Runtimes", "StateGraph"],
  ]

  /// Reads one package's manifest.
  ///
  /// - Parameter components: The package path relative to the Storefront suite.
  /// - Returns: The manifest's full text.
  /// - Throws: If the manifest is missing or unreadable — the loud failure that
  ///   stops a moved or renamed package from quietly reducing this suite to a
  ///   comparison of two things, or of one.
  static func manifestText(forPackage components: [String]) throws -> String {
    let packageDirectory = components.reduce(macrobenchmarkDirectory) {
      $0.appendingPathComponent($1)
    }
    let url = packageDirectory.appendingPathComponent("Package.swift")
    return try String(contentsOf: url, encoding: .utf8)
  }

  /// Extracts the `storefrontSwiftSettings` array literal from a manifest.
  ///
  /// Deliberately narrow: it takes the declaration line and every line through
  /// the first closing bracket at column zero, which is precisely the array a
  /// `swift format`-ed manifest produces. It does not tolerate a second
  /// declaration or a missing one, because either would mean the thing being
  /// compared is no longer the thing every target is built with.
  ///
  /// - Parameter manifest: The manifest's full text.
  /// - Returns: The settings block, or `nil` if it is absent or ambiguous.
  static func settingsBlock(in manifest: String) -> String? {
    let lines = manifest.split(separator: "\n", omittingEmptySubsequences: false)
    let declarations = lines.indices.filter {
      lines[$0].hasPrefix("let storefrontSwiftSettings")
    }
    guard declarations.count == 1, let start = declarations.first else { return nil }
    guard let end = lines[start...].firstIndex(where: { $0 == "]" }) else { return nil }
    return lines[start...end].joined(separator: "\n")
  }

  @Test("all four Storefront packages compile their targets identically")
  func settingsBlocksAreByteIdentical() throws {
    var blocks: [(package: String, block: String)] = []
    for components in Self.comparedPackagePaths {
      let package = components.joined(separator: "/")
      let manifest = try Self.manifestText(forPackage: components)
      let block = try #require(
        Self.settingsBlock(in: manifest),
        "Storefront/\(package)/Package.swift declares no single storefrontSwiftSettings block"
      )
      blocks.append((package, block))
    }
    try #require(blocks.count == Self.comparedPackagePaths.count)

    // Compare against the neutral workload's copy specifically: it defines the
    // protocol dialect every runtime implements.
    let reference = blocks[0]
    for candidate in blocks.dropFirst() {
      #expect(
        candidate.block == reference.block,
        """
        Storefront/\(candidate.package)/Package.swift compiles its targets \
        differently from Storefront/\(reference.package)/Package.swift, so a \
        comparison between them \
        would measure the settings rather than the runtimes.

        \(reference.package):
        \(reference.block)

        \(candidate.package):
        \(candidate.block)
        """
      )
    }
  }

  /// The block being compared is the one every target actually uses.
  ///
  /// Parity between four copies of a constant proves nothing if a target has
  /// stopped passing that constant to the compiler, so each manifest is also
  /// required to reference `storefrontSwiftSettings` once per target it
  /// declares. Counting `swiftSettings:` occurrences catches the case this
  /// guards against: a target given its own inline settings array would raise
  /// the `swiftSettings:` count without raising the reference count.
  @Test("every Storefront target is built with the shared settings")
  func everyTargetUsesTheSharedSettings() throws {
    for components in Self.comparedPackagePaths {
      let package = components.joined(separator: "/")
      let manifest = try Self.manifestText(forPackage: components)
      let lines = manifest.split(separator: "\n", omittingEmptySubsequences: false)
      let uses = lines.filter { $0.contains("swiftSettings: storefrontSwiftSettings") }.count
      let settingsSites = lines.filter { $0.contains("swiftSettings:") }.count
      #expect(
        uses > 0,
        "Storefront/\(package)/Package.swift builds no target with the shared settings"
      )
      #expect(
        uses == settingsSites,
        """
        Storefront/\(package)/Package.swift has \(settingsSites - uses) target(s) with settings of \
        their own, which the parity check above would not see.
        """
      )
    }
  }
}
