import CogLintFixtures
import Foundation

/// Generates CogLint rule articles from the package's executable fixture registry.
@main
struct CogLintDocGenerator {
  /// Validates every corpus and writes the seven deterministic Markdown articles.
  static func main() throws {
    let outputDirectory = try outputDirectory(from: Array(CommandLine.arguments.dropFirst()))
    try FileManager.default.createDirectory(
      at: outputDirectory,
      withIntermediateDirectories: true
    )

    for fixture in CogLintFixtureRegistry.all {
      let failures = CogLintFixtureHarness.failures(in: fixture)
      guard failures.isEmpty else {
        throw GenerationError(
          failures.map(\.description).joined(separator: "\n")
        )
      }

      let expectedRoute = fixture.rule.slug.replacingOccurrences(of: "-", with: "")
      guard fixture.rule.helpURL.lastPathComponent == expectedRoute else {
        throw GenerationError(
          "\(fixture.rule.slug) help URL ends in \(fixture.rule.helpURL.lastPathComponent); "
            + "expected \(expectedRoute)"
        )
      }

      let file = outputDirectory.appending(
        path: CogLintFixtureHarness.docCArticleFileName(for: fixture)
      )
      try CogLintFixtureHarness.docCArticle(for: fixture).write(
        to: file,
        atomically: true,
        encoding: .utf8
      )
      print("generated \(file.lastPathComponent) -> \(fixture.rule.helpURL.absoluteString)")
    }
  }

  /// Parses the deliberately narrow generator interface.
  private static func outputDirectory(from arguments: [String]) throws -> URL {
    guard arguments.count == 2, arguments[0] == "--output", !arguments[1].isEmpty else {
      throw GenerationError("usage: CogLintDocGenerator --output <Cog.docc directory>")
    }
    return URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL
  }
}

/// A user-facing generation failure that avoids an unexplained trap.
private struct GenerationError: Error, CustomStringConvertible {
  /// The complete explanation printed by SwiftPM.
  let description: String

  /// Creates one actionable generator failure.
  init(_ description: String) {
    self.description = description
  }
}
