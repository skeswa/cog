import Foundation
import SwiftSyntax

/// One fully located, rule-owned error ready for any reporter.
package struct CogLintFinding: Equatable, Sendable {
  /// The stable source path displayed to the caller.
  package let path: String

  /// The one-based physical source line.
  package let line: Int

  /// The one-based UTF-8 byte column used by compiler diagnostics.
  package let column: Int

  /// The stable rule slug displayed in square brackets.
  package let rule: String

  /// The convention-specific explanation of the violation.
  package let message: String

  /// The permanent DocC article for the violated rule.
  package let helpURL: URL

  /// Creates a reporter-neutral finding after source-location conversion.
  package init(
    path: String,
    line: Int,
    column: Int,
    rule: String,
    message: String,
    helpURL: URL
  ) {
    self.path = path
    self.line = line
    self.column = column
    self.rule = rule
    self.message = message
    self.helpURL = helpURL
  }

  /// Formats the finding in the compiler grammar parsed by Xcode.
  package var xcodeDescription: String {
    let singleLineMessage =
      message
      .replacingOccurrences(of: "\r\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
    return
      "\(path):\(line):\(column): error: [\(rule)] \(singleLineMessage) — \(helpURL.absoluteString)"
  }
}

/// The deterministic output and process disposition of one lint invocation.
package struct CogLintExecution: Equatable, Sendable {
  /// Every collected finding in reporter order.
  package let findings: [CogLintFinding]

  /// Creates an execution from a complete sorted finding list.
  package init(findings: [CogLintFinding]) {
    self.findings = findings
  }

  /// Whether the command must return a failing process status.
  package var hasErrors: Bool { !findings.isEmpty }

  /// The portable process status returned by the CLI for this execution.
  package var exitCode: Int32 { hasErrors ? 1 : 0 }

  /// The complete Xcode reporter payload, including its final newline when nonempty.
  package var xcodeOutput: String {
    guard !findings.isEmpty else { return "" }
    return findings.map(\.xcodeDescription).joined(separator: "\n") + "\n"
  }
}

/// Runs syntax-only rules over a deterministically discovered Swift file set.
package enum CogLintEngine {
  /// Reads, parses, and evaluates every selected file and rule.
  ///
  /// Rules are injectable so fixture tests can prove the shared engine before
  /// any production rule lands. Production surfaces pass
  /// ``CogLintRuleRegistry/all`` and therefore cannot diverge from each other.
  package static func lint(
    paths: [String],
    relativeTo currentDirectory: URL,
    rules: [any CogLintRule]
  ) throws -> CogLintExecution {
    let files = try CogLintPathDiscovery.discover(paths: paths, relativeTo: currentDirectory)
    var findings: [CogLintFinding] = []

    for file in files {
      let sourceText: String
      do {
        sourceText = try String(contentsOf: file.url, encoding: .utf8)
      } catch {
        throw CogLintInputError(
          "cannot read Swift source \(file.displayPath): \(error.localizedDescription)"
        )
      }

      let source = CogLintParser.parse(source: sourceText)
      let converter = SourceLocationConverter(fileName: file.displayPath, tree: source)
      for rule in rules {
        for violation in rule.violations(in: source) {
          let location = converter.location(for: violation.position)
          findings.append(
            CogLintFinding(
              path: file.displayPath,
              line: location.line,
              column: location.column,
              rule: rule.slug,
              message: violation.message,
              helpURL: rule.helpURL
            )
          )
        }
      }
    }

    findings.sort(by: findingPrecedes)
    return CogLintExecution(findings: findings)
  }

  /// Defines reporter order independently of input path, filesystem, and registry order.
  private static func findingPrecedes(_ lhs: CogLintFinding, _ rhs: CogLintFinding) -> Bool {
    if lhs.path != rhs.path { return lhs.path < rhs.path }
    if lhs.line != rhs.line { return lhs.line < rhs.line }
    if lhs.column != rhs.column { return lhs.column < rhs.column }
    if lhs.rule != rhs.rule { return lhs.rule < rhs.rule }
    return lhs.message < rhs.message
  }
}
