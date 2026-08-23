import CogLintCore
import CogLintFixtures
import Foundation
import Testing

// MARK: - LINT-12

/// Proves the production rule against its shared fixture positions and evasions.
@Test func `LINT-12 manual source privacy fixture is the rule specification`() {
  #expect(
    CogLintFixtureHarness.failures(in: CogLintFixtureRegistry.manualCogPrivate).isEmpty
  )
}

/// Proves the registered engine emits the settled slug, message, URL, and failing status.
@Test func `LINT-12 production registry reports a wider manual source`() throws {
  let root = FileManager.default.temporaryDirectory
    .appending(path: "coglint-manual-private-\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  try "let countSourceCog = Cog.Manual(0)\n".write(
    to: root.appending(path: "State.swift"),
    atomically: true,
    encoding: .utf8
  )

  let execution = try CogLintEngine.lint(
    paths: ["State.swift"],
    relativeTo: root,
    targetRole: .production,
    rules: CogLintRuleRegistry.all
  )

  #expect(execution.exitCode == 1)
  #expect(
    execution.xcodeOutput
      == "State.swift:1:5: error: [manual-cog-private] writable Cog sources must be `private` or `fileprivate`; expose `.readOnly` or an automatic cog — https://skeswa.github.io/cog/documentation/cog/manualcogprivate\n"
  )
}
