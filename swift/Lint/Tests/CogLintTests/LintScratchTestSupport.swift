import CogLintCore
import Foundation

/// Lints one scratch source through the shared engine in an isolated directory.
///
/// The engine rather than a rule alone is exercised so the settled slug,
/// message, help URL, and process status are proven together, and so a rule
/// that never reached ``CogLintRuleRegistry`` cannot pass its own suite. The
/// file name is the caller's because it appears verbatim in expected reporter
/// output; the scratch directory lives only for this call.
func lintScratchSource(
  _ source: String,
  named fileName: String,
  targetRole: CogLintTargetRole = .production,
  rules: [any CogLintRule] = CogLintRuleRegistry.all
) throws -> CogLintExecution {
  let root = FileManager.default.temporaryDirectory
    .appending(path: "coglint-scratch-\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  try source.write(to: root.appending(path: fileName), atomically: true, encoding: .utf8)
  return try CogLintEngine.lint(
    paths: [fileName],
    relativeTo: root,
    targetRole: targetRole,
    rules: rules
  )
}

/// Runs one filesystem scenario under an isolated, automatically removed directory.
///
/// For proofs whose subject is the filesystem itself — path discovery,
/// multi-file ordering — where one scratch source is not enough.
func withTemporaryLintDirectory(
  _ body: (URL) throws -> Void
) throws {
  let root = FileManager.default.temporaryDirectory
    .appending(path: "coglint-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  try body(root)
}

/// Writes a fixture after creating every parent directory required by its path.
func write(_ contents: String, to file: URL) throws {
  try FileManager.default.createDirectory(
    at: file.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try contents.write(to: file, atomically: true, encoding: .utf8)
}
