import Foundation
import PackagePlugin

#if canImport(XcodeProjectPlugin)
import XcodeProjectPlugin
#endif

/// Applies CogLint to the exact Swift inputs of one SwiftPM or Xcode target.
///
/// The plugin invokes only the packaged `coglint` binary. Its prebuild command
/// keeps a content-addressed result in the target-specific plugin work
/// directory, so every build still receives diagnostics while unchanged input
/// avoids reparsing. SwiftPM test targets select the explicit test role from
/// manifest target kind; every other target uses the conservative production
/// rules.
@main
struct CogLintBuildToolPlugin: BuildToolPlugin {
  /// Creates the SwiftPM prebuild command for source targets with Swift inputs.
  func createBuildCommands(
    context: PluginContext,
    target: any Target
  ) async throws -> [Command] {
    guard let sourceTarget = target as? any SourceModuleTarget else { return [] }
    let sourcePaths = sourceTarget.sourceFiles(withSuffix: "swift").map(\.url.path).sorted()
    let targetRole = sourceTarget.kind == .test ? "test" : "production"
    return commands(
      tool: try context.tool(named: "coglint").url,
      workDirectory: context.pluginWorkDirectoryURL,
      sourcePaths: sourcePaths,
      targetRole: targetRole,
      targetName: sourceTarget.name
    )
  }
}

#if canImport(XcodeProjectPlugin)
/// Adds the same binary and cache behavior when an Xcode target applies the plugin product.
extension CogLintBuildToolPlugin: XcodeBuildToolPlugin {
  /// Creates the Xcode prebuild command over the target membership Xcode supplies.
  func createBuildCommands(
    context: XcodePluginContext,
    target: XcodeTarget
  ) throws -> [Command] {
    let sourcePaths = target.inputFiles
      .map(\.url)
      .filter { $0.pathExtension == "swift" }
      .map(\.path)
      .sorted()
    return commands(
      tool: try context.tool(named: "coglint").url,
      workDirectory: context.pluginWorkDirectoryURL,
      sourcePaths: sourcePaths,
      targetRole: "production",
      targetName: target.displayName
    )
  }
}
#endif

/// Creates the single prebuild command shared by SwiftPM and Xcode adapters.
private func commands(
  tool: URL,
  workDirectory: URL,
  sourcePaths: [String],
  targetRole: String,
  targetName: String
) -> [Command] {
  guard !sourcePaths.isEmpty else { return [] }
  let cacheURL = workDirectory.appending(path: "coglint-cache-v1.json")
  let outputsURL = workDirectory.appending(path: "Generated")
  return [
    .prebuildCommand(
      displayName: "CogLint \(targetName)",
      executable: tool,
      arguments: [
        "--target-role", targetRole,
        "--reporter", "xcode",
        "--cache-path", cacheURL.path,
      ] + sourcePaths,
      outputFilesDirectory: outputsURL
    )
  ]
}
