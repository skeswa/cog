import Foundation
import PackagePlugin

#if canImport(XcodeProjectPlugin)
import XcodeProjectPlugin
#endif

/// Exposes the packaged CogLint CLI as `swift package coglint` without another engine.
///
/// Every argument is forwarded unchanged, and the tool runs from the consumer
/// package or Xcode project directory. Relative paths, explicit target role,
/// reporter selection, diagnostics, and exit status therefore retain the bare
/// CLI contract instead of acquiring a plugin-specific interpretation.
@main
struct CogLintCommandPlugin: CommandPlugin {
  /// Runs CogLint from a SwiftPM consumer package with its original arguments.
  func performCommand(
    context: PluginContext,
    arguments: [String]
  ) async throws {
    try runCogLint(
      tool: context.tool(named: "coglint").url,
      arguments: arguments,
      currentDirectory: context.package.directoryURL
    )
  }
}

#if canImport(XcodeProjectPlugin)
/// Makes the same on-demand command available to Xcode package integrations.
extension CogLintCommandPlugin: XcodeCommandPlugin {
  /// Runs CogLint relative to the project whose package command was invoked.
  func performCommand(
    context: XcodePluginContext,
    arguments: [String]
  ) throws {
    try runCogLint(
      tool: context.tool(named: "coglint").url,
      arguments: arguments,
      currentDirectory: context.xcodeProject.directoryURL
    )
  }
}
#endif

/// Executes the binary with inherited streams and preserves its failing disposition.
private func runCogLint(
  tool: URL,
  arguments: [String],
  currentDirectory: URL
) throws {
  let process = Process()
  process.executableURL = tool
  process.arguments = arguments
  process.currentDirectoryURL = currentDirectory
  process.standardInput = FileHandle.standardInput
  process.standardOutput = FileHandle.standardOutput
  process.standardError = FileHandle.standardError
  try process.run()
  process.waitUntilExit()
  guard process.terminationReason == .exit && process.terminationStatus == 0 else {
    throw CogLintCommandPluginFailure(
      reason: process.terminationReason,
      status: process.terminationStatus
    )
  }
}

/// The child disposition SwiftPM uses to fail the command-plugin invocation.
private struct CogLintCommandPluginFailure: Error, CustomStringConvertible {
  /// Whether CogLint exited normally or was terminated by an external signal.
  let reason: Process.TerminationReason

  /// The original process exit code or terminating signal.
  let status: Int32

  /// A stable plugin-level explanation written after CogLint reporter output.
  var description: String {
    switch reason {
    case .exit: "coglint exited with status \(status)"
    case .uncaughtSignal: "coglint was terminated by signal \(status)"
    @unknown default: "coglint ended for an unknown reason with status \(status)"
    }
  }
}
