import CogLintCore
import Foundation
import SwiftSyntax
import Testing

// MARK: - LINT-03

/// Proves an exact directive suppresses its named rule on only the next physical line.
@Test func `LINT-03 exact directive reaches one rule on one physical line`() throws {
  let execution = try lint(
    """
    // coglint:disable-next-line fixture-sentinel -- generated spelling is intentional
    let badName = 0
    let badName = 1
    """
  )

  #expect(execution.findings.map(\.line) == [3])
  #expect(execution.exitCode == 1)

  let crlfExecution = try lint(
    "// coglint:disable-next-line fixture-sentinel -- CRLF is still one physical line\r\n"
      + "let badName = 0\r\nlet badName = 1\r\n"
  )
  #expect(crlfExecution.findings.map(\.line) == [3])
}

/// Proves a directive neither hides another rule nor crosses a blank physical line.
@Test func `LINT-03 suppression does not leak by rule or line`() throws {
  let source =
    """
    // coglint:disable-next-line fixture-sentinel -- only this rule is waived
    let badName = 0
    // coglint:disable-next-line fixture-sentinel -- the blank line consumes this waiver

    let badName = 1
    """

  let execution = try lint(source, rules: [SuppressionSentinelRule(), OtherSentinelRule()])

  #expect(
    execution.findings.map { "\($0.rule)@\($0.line)" } == [
      "other-sentinel@2", "fixture-sentinel@5", "other-sentinel@5",
    ]
  )
}

/// Proves a missing reason suppresses nothing and teaches the accepted exact form.
@Test func `LINT-03 missing reason reports the underlying error with suppression help`() throws {
  let attempts = [
    "// coglint:disable-next-line fixture-sentinel --",
    "// coglint:disable-next-line fixture-sentinel --    ",
  ]
  for attempt in attempts {
    let execution = try lint(attempt + "\nlet badName = 0\n")

    #expect(execution.findings.count == 1)
    #expect(
      execution.findings.first?.message
        == "sentinel violation; suppress only with `// coglint:disable-next-line fixture-sentinel -- <non-empty reason>`"
    )
  }
}

/// Proves target role is explicit rule context rather than a filename heuristic.
@Test func `LINT-03 explicit test target role enables only the rule owned exemption`() throws {
  let production = try lint("let badName = 0\n", role: .production)
  let test = try lint("let badName = 0\n", role: .test)

  #expect(production.exitCode == 1)
  #expect(test.exitCode == 0)
}

/// A role-aware sentinel that mirrors the later primitive rule's test exemption.
private struct SuppressionSentinelRule: CogLintRule {
  /// The exact rule name used by suppression fixtures.
  let slug = "fixture-sentinel"

  /// The inert test help route.
  let helpURL = URL(string: "https://example.invalid/fixture-sentinel")!

  /// Reports sentinel tokens only for the production role.
  func violations(
    in source: SourceFileSyntax,
    context: CogLintRuleContext
  ) -> [CogLintViolation] {
    guard context.targetRole == .production else { return [] }
    return sentinelViolations(in: source, message: "sentinel violation")
  }
}

/// A second rule that proves a valid directive never suppresses by source line alone.
private struct OtherSentinelRule: CogLintRule {
  /// A distinct target that no suppression fixture names.
  let slug = "other-sentinel"

  /// The second inert help route.
  let helpURL = URL(string: "https://example.invalid/other-sentinel")!

  /// Reports the same token so rule-specific filtering is directly observable.
  func violations(
    in source: SourceFileSyntax,
    context _: CogLintRuleContext
  ) -> [CogLintViolation] {
    sentinelViolations(in: source, message: "other sentinel violation")
  }
}

/// Runs one suppression source through the shared engine in an isolated directory.
private func lint(
  _ source: String,
  role: CogLintTargetRole = .production,
  rules: [any CogLintRule] = [SuppressionSentinelRule()]
) throws -> CogLintExecution {
  try lintScratchSource(source, named: "Fixture.swift", targetRole: role, rules: rules)
}

/// Finds every sentinel identifier in source order with one supplied message.
private func sentinelViolations(
  in source: SourceFileSyntax,
  message: String
) -> [CogLintViolation] {
  source.tokens(viewMode: .sourceAccurate).compactMap { token in
    guard token.text == "badName" else { return nil }
    return CogLintViolation(message: message, at: token)
  }
}
