import Foundation
import Testing

@testable import CogStorefront

/// How many Cog declarations the Storefront actually declares, counted rather
/// than described.
///
/// The rest of the workload's shape, profiles, catalog, pricing ladder, search
/// plan, steady interactions, compute control, is runtime-neutral and is
/// asserted in `StorefrontWorkloadShapeTests`. What stays here is the one claim
/// that is specifically about *Cog*: the declaration count `impl/perf.md`
/// quotes beside every recorded number. It is cheap and it runs in the
/// package's ordinary suite, because a workload that silently grew a
/// declaration would otherwise make every recorded number incomparable with the
/// one before it.
@Suite("Storefront declaration census")
struct StorefrontShapeTests {
  /// The declaration census, hand-written here and mechanically checked below.
  ///
  /// These are the numbers `impl/perf.md` quotes. If a declaration is added or
  /// removed, this test fails first and the record is updated deliberately
  /// rather than drifting.
  static let expectedDeclarationCounts: [String: Int] = [
    "Cog.Manual": 12,
    "CogBox.Manual": 5,
    "Cog": 18,
    "CogBox": 8,
    "Cog.Async": 7,
    "CogBox.Async": 3,
  ]

  /// The directory holding the `CogStorefront` module's sources, derived from
  /// this file's path.
  ///
  /// A `#filePath` walk rather than a bundle resource because the census reads
  /// source text, which is not a build product. The walk is spelled with one
  /// comment per level so a future move of this file is a visible edit rather
  /// than a silent miscount: this file sits at
  /// `Tests/CogStorefrontTests/StorefrontShapeTests.swift`, so three
  /// deletions land on the package root and the two components below name the
  /// Cog target. ``sourceFileURLs()`` refuses an empty result, which is the
  /// guard that makes a wrong answer here fail loudly instead of censusing
  /// nothing and passing.
  static var sourcesDirectory: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // Tests/CogStorefrontTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // Workload, the package root
      .appendingPathComponent("Sources")
      .appendingPathComponent("CogStorefront")
  }

  /// Every Swift source file the census reads.
  ///
  /// Separate from ``declarationCounts()`` so that "the glob found nothing" and
  /// "the glob found files with no declarations in them" are distinguishable
  /// failures. They were not before: a census over a directory that had moved
  /// returned an empty dictionary, every `default: 0` lookup compared zero
  /// against zero for a kind that was absent, and the suite stayed green while
  /// measuring nothing at all.
  ///
  /// - Returns: The `.swift` files directly under ``sourcesDirectory``.
  /// - Throws: If the directory does not exist, which is the loud failure this
  ///   split exists to produce.
  static func sourceFileURLs() throws -> [URL] {
    try FileManager.default
      .contentsOfDirectory(at: sourcesDirectory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "swift" }
  }

  /// Counts file-scope declarations of each Cog kind across the module.
  ///
  /// Syntax-only, deliberately: a census that resolved types would need a
  /// compiler, and a census that trusted a hand-maintained list would not be a
  /// census. A declaration is counted when a `let` binding at column zero is
  /// initialized with one of the six nominal spellings.
  static func declarationCounts() throws -> [String: Int] {
    var counts: [String: Int] = [:]
    for file in try sourceFileURLs() {
      let text = try String(contentsOf: file, encoding: .utf8)
      for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        // File scope only: a declaration inside a type or a function is
        // indented, and a local Cog is invisible to this census exactly as it
        // is to CogLint's own classifier.
        guard line.first != " ", line.contains("let ") else { continue }
        guard
          let family = line.contains("= CogBox<") ? "CogBox" : line.contains("= Cog<") ? "Cog" : nil
        else { continue }
        let member =
          line.contains(">.Manual") ? ".Manual" : line.contains(">.Async") ? ".Async" : ""
        counts[family + member, default: 0] += 1
      }
    }
    return counts
  }

  @Test("the declaration census is exactly what impl/perf.md records")
  func declarationCensus() throws {
    // The guard risk this census carried from the day it was written: it reads
    // source text over a relative path, so a target that moved would have made
    // it count nothing and pass. An empty glob is now a failure of its own.
    let files = try Self.sourceFileURLs()
    try #require(
      !files.isEmpty,
      "no Swift sources under \(Self.sourcesDirectory.path); the census read nothing"
    )

    let counts = try Self.declarationCounts()
    for (kind, expected) in Self.expectedDeclarationCounts {
      #expect(counts[kind, default: 0] == expected, "\(kind) count drifted")
    }
  }
}
