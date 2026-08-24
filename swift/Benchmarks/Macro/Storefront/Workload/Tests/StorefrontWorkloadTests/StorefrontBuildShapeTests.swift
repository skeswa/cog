import Foundation
import Testing

/// Build-shape parity across the three packages the comparison is compiled in.
///
/// The workload is one script run by four runtimes, but those runtimes are
/// spread over three SwiftPM packages — `cog-storefront` (the workload and the
/// Cog port), `cog-storefront-runtimes` (the two `@Observable` ports), and
/// `cog-storefront-state-graph` (the swift-state-graph port) — because a
/// package hands its dependencies to everyone who resolves it. Each package
/// therefore carries its own copy of the compiler settings every one of its
/// targets is built with, and SwiftPM manifests cannot import one another, so
/// nothing but this suite makes the copies agree.
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
  /// The `Macro/Storefront/` directory the three packages sit under, derived
  /// from this file's path.
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
      .deletingLastPathComponent()  // Tests/StorefrontWorkloadTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // Workload, the package root
      .deletingLastPathComponent()  // Macro/Storefront
  }

  /// The directory names of the three packages whose settings must agree, in
  /// the order a failure message reads best.
  ///
  /// Directory names rather than manifest names (`cog-storefront` and friends)
  /// because that is what the walk above needs, and because SwiftPM's own
  /// identity rule already makes the last path component the name these
  /// packages refer to each other by.
  static let comparedPackageDirectories = [
    "Workload",
    "Runtimes",
    "StateGraph",
  ]

  /// Reads one package's manifest.
  ///
  /// - Parameter directory: The package directory under `Macro/Storefront/`.
  /// - Returns: The manifest's full text.
  /// - Throws: If the manifest is missing or unreadable — the loud failure that
  ///   stops a moved or renamed package from quietly reducing this suite to a
  ///   comparison of two things, or of one.
  static func manifestText(forPackage directory: String) throws -> String {
    let url =
      macrobenchmarkDirectory
      .appendingPathComponent(directory)
      .appendingPathComponent("Package.swift")
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

  @Test("all three Storefront packages compile their targets identically")
  func settingsBlocksAreByteIdentical() throws {
    var blocks: [(package: String, block: String)] = []
    for directory in Self.comparedPackageDirectories {
      let manifest = try Self.manifestText(forPackage: directory)
      let block = try #require(
        Self.settingsBlock(in: manifest),
        "Macro/Storefront/\(directory)/Package.swift declares no single storefrontSwiftSettings block"
      )
      blocks.append((directory, block))
    }
    try #require(blocks.count == Self.comparedPackageDirectories.count)

    // Compared against the workload package's copy specifically, rather than
    // against whichever came first: `cog-storefront` is the package the other
    // two depend on, so it is the one whose settings the ports are matching.
    let reference = blocks[0]
    for candidate in blocks.dropFirst() {
      #expect(
        candidate.block == reference.block,
        """
        Macro/Storefront/\(candidate.package)/Package.swift compiles its targets \
        differently from Macro/Storefront/\(reference.package)/Package.swift, so a \
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
  /// Parity between three copies of a constant proves nothing if a target has
  /// stopped passing that constant to the compiler, so each manifest is also
  /// required to reference `storefrontSwiftSettings` once per target it
  /// declares. Counting `swiftSettings:` occurrences catches the case this
  /// guards against: a target given its own inline settings array would raise
  /// the `swiftSettings:` count without raising the reference count.
  @Test("every Storefront target is built with the shared settings")
  func everyTargetUsesTheSharedSettings() throws {
    for directory in Self.comparedPackageDirectories {
      let manifest = try Self.manifestText(forPackage: directory)
      let lines = manifest.split(separator: "\n", omittingEmptySubsequences: false)
      let uses = lines.filter { $0.contains("swiftSettings: storefrontSwiftSettings") }.count
      let settingsSites = lines.filter { $0.contains("swiftSettings:") }.count
      #expect(
        uses > 0,
        "Macro/Storefront/\(directory)/Package.swift builds no target with the shared settings"
      )
      #expect(
        uses == settingsSites,
        """
        Macro/Storefront/\(directory)/Package.swift has \(settingsSites - uses) target(s) with settings of \
        their own, which the parity check above would not see.
        """
      )
    }
  }
}
