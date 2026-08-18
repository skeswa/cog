import CogLintCore
import CogLintFixtures
import Foundation
import Testing

// MARK: - LINT-07

/// Proves view storage and parameter boundaries against the shared corpus.
@Test func `LINT-07 view graph boundary fixture is the rule specification`() {
  #expect(CogLintFixtureHarness.failures(in: CogLintFixtureRegistry.noCogsInViewInit).isEmpty)
}

/// Proves the registered rule emits its environment-focused repair guidance.
@Test func `LINT-07 production registry reports a view initializer parameter`() throws {
  let root = FileManager.default.temporaryDirectory
    .appending(path: "coglint-view-init-\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  try "struct Panel: View { init(cogs: Cogs) {} }\n".write(
    to: root.appending(path: "Panel.swift"),
    atomically: true,
    encoding: .utf8
  )

  let execution = try CogLintEngine.lint(
    paths: ["Panel.swift"],
    relativeTo: root,
    targetRole: .production,
    rules: CogLintRuleRegistry.all
  )

  #expect(execution.exitCode == 1)
  #expect(
    execution.xcodeOutput
      == "Panel.swift:1:33: error: [no-cogs-in-view-init] views must resolve `Cogs` with `@Environment(\\.cogs)`, not store or accept it — https://skeswa.github.io/cog/documentation/cog/nocogsinviewinit\n"
  )
}
