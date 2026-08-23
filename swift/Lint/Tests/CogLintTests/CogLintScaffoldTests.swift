import CogLintCore
import Foundation
import Testing

/// Proves that lint-only source dependencies remain outside Cog's root graph.
///
/// The DocC plugin is environment-gated in the root manifest, so this check
/// explicitly removes that opt-in before asking SwiftPM for the graph an
/// ordinary consumer resolves. Requiring the root node to have no children is
/// stronger than searching only for today's two lint dependency names.
@Test
func rootManifestExcludesLintDependencies() throws {
  let graph = try rootDependencyGraph()

  // SwiftPM derives a root identity from the checkout directory, so an
  // archive or consumer cache need not call the directory `cog`. The manifest
  // name is the stable proof that this is Cog's root package.
  #expect(graph.name == "cog")
  #expect(graph.dependencies.isEmpty)
  #expect(
    Set(graph.flattenedIdentities).isDisjoint(with: [
      "swift-syntax", "swift-argument-parser",
    ])
  )
}

/// One node from SwiftPM's recursive JSON dependency graph.
private struct DependencyNode: Decodable {
  /// The package name declared by its manifest.
  let name: String

  /// SwiftPM's canonical package identity, independent of display name.
  let identity: String

  /// Direct dependency nodes in resolver order.
  let dependencies: [DependencyNode]

  /// Every identity reachable from this node, including the node itself.
  var flattenedIdentities: [String] {
    [identity] + dependencies.flatMap(\.flattenedIdentities)
  }
}

/// A failed root-graph command with its diagnostic output preserved.
private struct DependencyGraphCommandError: Error, CustomStringConvertible {
  /// The SwiftPM process status and combined output needed to diagnose CI.
  let description: String
}

/// Reads the root dependency graph using the selected Swift toolchain.
private func rootDependencyGraph() throws -> DependencyNode {
  let lintPackageDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let repositoryDirectory =
    lintPackageDirectory
    .deletingLastPathComponent()
    .deletingLastPathComponent()

  let outputPipe = Pipe()
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = [
    "swift", "package", "--package-path", repositoryDirectory.path,
    "show-dependencies", "--format", "json",
  ]
  process.standardOutput = outputPipe
  process.standardError = outputPipe

  var environment = ProcessInfo.processInfo.environment
  environment.removeValue(forKey: "COG_DOCC")
  process.environment = environment

  try process.run()
  let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()

  guard process.terminationStatus == 0 else {
    let output = String(decoding: outputData, as: UTF8.self)
    throw DependencyGraphCommandError(
      description: "swift package show-dependencies exited \(process.terminationStatus):\n\(output)"
    )
  }

  return try JSONDecoder().decode(DependencyNode.self, from: outputData)
}
