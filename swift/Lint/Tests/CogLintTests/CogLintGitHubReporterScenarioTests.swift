import CogLintCore
import Foundation
import Testing

// MARK: - LINT-15

/// Proves each shared finding becomes one escaped annotation with equivalent fields.
@Test func `LINT-15 GitHub reporter escapes properties and annotation data`() {
  let execution = CogLintExecution(findings: [
    CogLintFinding(
      path: "Sources/Weather%,Card:One.swift",
      line: 7,
      column: 19,
      rule: "rule%,:one",
      message: "first 100%\r\nsecond: still, one finding",
      helpURL: URL(string: "https://example.invalid/help?q=a%20b")!
    ),
    CogLintFinding(
      path: "Sources/Plain.swift",
      line: 11,
      column: 3,
      rule: "plain-rule",
      message: "plain message",
      helpURL: URL(string: "https://example.invalid/plain")!
    ),
  ])

  #expect(
    execution.githubOutput
      == "::error file=Sources/Weather%25%2CCard%3AOne.swift,line=7,col=19,title=rule%25%2C%3Aone::[rule%25,:one] first 100%25%0D%0Asecond: still, one finding — https://example.invalid/help?q=a%2520b\n"
      + "::error file=Sources/Plain.swift,line=11,col=3,title=plain-rule::[plain-rule] plain message — https://example.invalid/plain\n"
  )
  #expect(execution.githubOutput.split(separator: "\n").count == execution.findings.count)
}

/// Proves a clean run and reporter selection retain the shared execution disposition.
@Test func `LINT-15 reporter selection does not change clean or failing status`() throws {
  let clean = CogLintExecution(findings: [])
  #expect(try clean.output(for: .github).isEmpty)
  #expect(try clean.output(for: .xcode).isEmpty)
  #expect(clean.exitCode == 0)

  let finding = CogLintFinding(
    path: "State.swift",
    line: 1,
    column: 1,
    rule: "manual-cog-private",
    message: "source is visible",
    helpURL: URL(string: "https://example.invalid/manual")!
  )
  let failing = CogLintExecution(findings: [finding])
  #expect(try failing.output(for: .github) == finding.githubDescription + "\n")
  #expect(try failing.output(for: .xcode) == finding.xcodeDescription + "\n")
  #expect(failing.exitCode == 1)
}
