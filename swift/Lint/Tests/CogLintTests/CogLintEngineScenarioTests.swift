import CogLintCore
import Foundation
import SwiftSyntax
import Testing

// MARK: - LINT-01

/// Proves that mixed and overlapping path inputs discover each visible Swift file once.
@Test func `LINT-01 path discovery is recursive deduplicated and deterministic`() throws {
  try withTemporaryLintDirectory { root in
    try write("let root = 0\n", to: root.appending(path: "Z.swift"))
    try write("let alpha = 0\n", to: root.appending(path: "Sources/Alpha.swift"))
    try write("let nested = 0\n", to: root.appending(path: "Sources/Nested/Beta.swift"))
    try write("ignored\n", to: root.appending(path: "Sources/Notes.txt"))
    try write("let hidden = 0\n", to: root.appending(path: "Sources/.Hidden.swift"))

    let files = try CogLintPathDiscovery.discover(
      paths: ["Z.swift", "Sources", "Sources/Alpha.swift"],
      relativeTo: root
    )

    #expect(
      files.map(\.displayPath) == [
        "Sources/Alpha.swift", "Sources/Nested/Beta.swift", "Z.swift",
      ]
    )
  }
}

/// Proves exact UTF-8 locations, reporter grammar, help URLs, order, and failure status.
@Test func `LINT-01 findings use exact Xcode diagnostics and fail the execution`() throws {
  try withTemporaryLintDirectory { root in
    try write("let badName = 0\n", to: root.appending(path: "Zeta.swift"))
    try write("let café = badName\n", to: root.appending(path: "Alpha.swift"))

    let execution = try CogLintEngine.lint(
      paths: ["Zeta.swift", "."],
      relativeTo: root,
      targetRole: .production,
      rules: [EngineSentinelRule()]
    )

    #expect(execution.hasErrors)
    #expect(execution.exitCode == 1)
    #expect(
      execution.xcodeOutput
        == "Alpha.swift:1:13: error: [fixture-sentinel] sentinel violation — https://example.invalid/fixture-sentinel\n"
        + "Zeta.swift:1:5: error: [fixture-sentinel] sentinel violation — https://example.invalid/fixture-sentinel\n"
    )
  }
}

/// Proves that a clean explicit input produces no diagnostics and a successful disposition.
@Test func `LINT-01 clean input exits successfully`() throws {
  try withTemporaryLintDirectory { root in
    try write("let weatherCog = 0\n", to: root.appending(path: "Clean.swift"))

    let execution = try CogLintEngine.lint(
      paths: ["Clean.swift"],
      relativeTo: root,
      targetRole: .production,
      rules: [EngineSentinelRule()]
    )

    #expect(!execution.hasErrors)
    #expect(execution.exitCode == 0)
    #expect(execution.xcodeOutput.isEmpty)
  }
}

/// A minimal injected rule that exercises the production engine without shipping early policy.
private struct EngineSentinelRule: CogLintRule {
  /// The stable test rule identifier.
  let slug = "fixture-sentinel"

  /// The stable test help URL printed by the Xcode reporter.
  let helpURL = URL(string: "https://example.invalid/fixture-sentinel")!

  /// Finds every sentinel token in source order.
  func violations(
    in source: SourceFileSyntax,
    context _: CogLintRuleContext
  ) -> [CogLintViolation] {
    source.tokens(viewMode: .sourceAccurate).compactMap { token in
      guard token.text == "badName" else { return nil }
      return CogLintViolation(message: "sentinel violation", at: token)
    }
  }
}
