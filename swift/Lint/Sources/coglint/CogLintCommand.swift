import ArgumentParser
import CogLintCore
import Foundation

/// The command-line boundary for Cog's syntax-only convention checker.
///
/// This boundary owns only argument parsing, standard output, and process
/// status. Discovery, rule execution, location conversion, and formatting stay
/// in `CogLintCore` so plugins and direct CLI use cannot diverge.
@main
struct CogLintCommand: ParsableCommand {
  /// The stable shell spelling shared by the bare CLI and command plugin.
  static let configuration = CommandConfiguration(commandName: "coglint")

  /// Explicit Swift files and directories searched recursively for Swift sources.
  @Argument(help: "Swift files and directories to lint")
  var paths: [String] = []

  /// The explicit source-target role; test enables only documented test exemptions.
  @Option(help: "Target role: production or test")
  var targetRole = CogLintTargetRole.production.rawValue

  /// The diagnostic serialization selected for this invocation.
  @Option(help: "Reporter: xcode, github, or sarif")
  var reporter = CogLintReporter.xcode.rawValue

  /// Rejects an empty invocation instead of reporting a misleading clean run.
  func validate() throws {
    guard !paths.isEmpty else {
      throw ValidationError("at least one Swift file or directory is required")
    }
    guard CogLintTargetRole(rawValue: targetRole) != nil else {
      throw ValidationError("target role must be `production` or `test`")
    }
    guard CogLintReporter(rawValue: reporter) != nil else {
      throw ValidationError("reporter must be `xcode`, `github`, or `sarif`")
    }
  }

  /// Runs the production registry, prints Xcode diagnostics, and fails on errors.
  mutating func run() throws {
    let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    guard let selectedRole = CogLintTargetRole(rawValue: targetRole) else {
      throw ValidationError("target role must be `production` or `test`")
    }
    guard let selectedReporter = CogLintReporter(rawValue: reporter) else {
      throw ValidationError("reporter must be `xcode`, `github`, or `sarif`")
    }
    let execution = try CogLintEngine.lint(
      paths: paths,
      relativeTo: currentDirectory,
      targetRole: selectedRole,
      rules: CogLintRuleRegistry.all
    )
    let output = try execution.output(for: selectedReporter)
    if !output.isEmpty {
      FileHandle.standardOutput.write(Data(output.utf8))
    }
    if execution.exitCode != 0 {
      throw ExitCode.failure
    }
  }
}
