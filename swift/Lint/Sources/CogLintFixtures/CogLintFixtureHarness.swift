import CogLintCore
import Foundation
import SwiftSyntax

/// One stable explanation of why a rule fixture does not match its contract.
package struct CogLintFixtureFailure: Equatable, Sendable, CustomStringConvertible {
  /// The complete failure text surfaced by Swift Testing and CI.
  package let description: String

  /// Creates a fixture failure whose text is suitable for direct test output.
  package init(_ description: String) {
    self.description = description
  }
}

/// Executes rule fixtures and renders their canonical DocC example fragments.
///
/// The harness is a regular package target rather than test-only code so the
/// later DocC generator consumes precisely the same corpus and renderer that
/// rule tests validate.
package enum CogLintFixtureHarness {
  /// Returns every structural or behavioral mismatch in deterministic order.
  ///
  /// All examples are checked even after an earlier failure, giving a rule
  /// author one complete repair list without allowing one passing category to
  /// conceal an empty or drifting sibling category.
  package static func failures(in fixture: CogLintRuleFixture) -> [CogLintFixtureFailure] {
    var failures: [CogLintFixtureFailure] = []
    validateStructure(of: fixture, into: &failures)
    let context = CogLintRuleContext(targetRole: fixture.targetRole)

    for triggering in fixture.triggering {
      let source = CogLintParser.parse(source: triggering.example.source)
      let actual = positions(of: fixture.rule.violations(in: source, context: context), in: source)
      if actual != triggering.positions {
        failures.append(
          CogLintFixtureFailure(
            "\(fixture.rule.slug) triggering example \(quoted(triggering.example.name)) "
              + "expected positions \(describe(triggering.positions)); got \(describe(actual))"
          )
        )
      }
    }

    for example in fixture.nonTriggering {
      validateClean(
        example,
        category: "non-triggering",
        rule: fixture.rule,
        context: context,
        into: &failures
      )
    }
    for example in fixture.acceptedEvasions {
      validateClean(
        example,
        category: "accepted evasion",
        rule: fixture.rule,
        context: context,
        into: &failures
      )
    }

    return failures
  }

  /// Renders the example sections inserted into a rule's DocC article.
  ///
  /// Rendering reads the same source values as `failures(in:)`; callers never
  /// maintain a second Markdown copy. The generated warning and stable section
  /// order make checked-in fragments auditable and deterministic.
  package static func docCExampleFragment(for fixture: CogLintRuleFixture) -> String {
    var lines = [
      "<!-- Generated from the \(fixture.rule.slug) CogLint fixture corpus; do not edit. -->",
      "",
      "## Triggering examples",
      "",
    ]

    for triggering in fixture.triggering {
      append(
        triggering.example,
        note: "Expected diagnostic positions: \(describe(triggering.positions)).",
        to: &lines
      )
    }

    lines.append(contentsOf: ["## Non-triggering examples", ""])
    for example in fixture.nonTriggering {
      append(example, note: nil, to: &lines)
    }

    lines.append(contentsOf: ["## Accepted evasions", ""])
    for example in fixture.acceptedEvasions {
      append(example, note: nil, to: &lines)
    }

    return lines.joined(separator: "\n") + "\n"
  }

  /// Renders the complete checked-in DocC article for one rule fixture.
  ///
  /// The kebab-case heading is intentional: DocC removes its hyphens for the
  /// native article identifier used by the permanent diagnostic URL.
  package static func docCArticle(for fixture: CogLintRuleFixture) -> String {
    let documentation = fixture.documentation
    let prose = """
      # \(fixture.rule.slug)

      \(documentation.violation)

      ## Why this rule exists

      \(documentation.rationale)

      ## How to fix it

      \(documentation.repair)

      """
    let examples = docCExampleFragment(for: fixture).trimmingCharacters(in: .newlines)
    return prose + "\n" + examples + "\n"
  }

  /// Returns the stable UpperCamelCase source name for a rule article.
  package static func docCArticleFileName(for fixture: CogLintRuleFixture) -> String {
    let stem = fixture.rule.slug.split(separator: "-").map { component in
      component.prefix(1).uppercased() + component.dropFirst()
    }.joined()
    return "\(stem).md"
  }

  /// Checks that all three categories and their documentation fields exist.
  private static func validateStructure(
    of fixture: CogLintRuleFixture,
    into failures: inout [CogLintFixtureFailure]
  ) {
    if fixture.rule.slug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      failures.append(CogLintFixtureFailure("fixture rule slug must not be empty"))
    }
    validateDocumentationProse(of: fixture, into: &failures)
    if fixture.triggering.isEmpty {
      failures.append(CogLintFixtureFailure("\(fixture.rule.slug) has no triggering examples"))
    }
    if fixture.nonTriggering.isEmpty {
      failures.append(CogLintFixtureFailure("\(fixture.rule.slug) has no non-triggering examples"))
    }
    if fixture.acceptedEvasions.isEmpty {
      failures.append(CogLintFixtureFailure("\(fixture.rule.slug) has no accepted evasions"))
    }

    for triggering in fixture.triggering {
      validateDocumentation(of: triggering.example, rule: fixture.rule, into: &failures)
      if triggering.positions.isEmpty {
        failures.append(
          CogLintFixtureFailure(
            "\(fixture.rule.slug) triggering example \(quoted(triggering.example.name)) "
              + "has no expected positions"
          )
        )
      }
    }
    for example in fixture.nonTriggering + fixture.acceptedEvasions {
      validateDocumentation(of: example, rule: fixture.rule, into: &failures)
    }
  }

  /// Checks the prose sections required by every generated rule article.
  private static func validateDocumentationProse(
    of fixture: CogLintRuleFixture,
    into failures: inout [CogLintFixtureFailure]
  ) {
    let fields = [
      ("violation", fixture.documentation.violation),
      ("rationale", fixture.documentation.rationale),
      ("repair", fixture.documentation.repair),
    ]
    for (name, value) in fields
    where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      failures.append(CogLintFixtureFailure("\(fixture.rule.slug) has no documentation \(name)"))
    }
  }

  /// Checks the prose fields needed to generate an understandable article.
  private static func validateDocumentation(
    of example: CogLintFixtureExample,
    rule: any CogLintRule,
    into failures: inout [CogLintFixtureFailure]
  ) {
    if example.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      failures.append(CogLintFixtureFailure("\(rule.slug) has an example with no name"))
    }
    if example.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      failures.append(
        CogLintFixtureFailure(
          "\(rule.slug) example \(quoted(example.name)) has no explanation"
        )
      )
    }
    if example.source.isEmpty {
      failures.append(
        CogLintFixtureFailure("\(rule.slug) example \(quoted(example.name)) has empty source")
      )
    }
  }

  /// Requires one example intended to stay clean to produce no violations.
  private static func validateClean(
    _ example: CogLintFixtureExample,
    category: String,
    rule: any CogLintRule,
    context: CogLintRuleContext,
    into failures: inout [CogLintFixtureFailure]
  ) {
    let source = CogLintParser.parse(source: example.source)
    let actual = positions(of: rule.violations(in: source, context: context), in: source)
    if !actual.isEmpty {
      failures.append(
        CogLintFixtureFailure(
          "\(rule.slug) \(category) \(quoted(example.name)) expected no diagnostics; got "
            + describe(actual)
        )
      )
    }
  }

  /// Converts offsets against the exact parsed buffer that produced them.
  private static func positions(
    of violations: [CogLintViolation],
    in source: SourceFileSyntax
  ) -> [CogLintFixturePosition] {
    let converter = SourceLocationConverter(fileName: "Fixture.swift", tree: source)
    return violations.map { violation in
      let location = converter.location(for: violation.position)
      return CogLintFixturePosition(line: location.line, column: location.column)
    }
  }

  /// Appends one example using a fence longer than any run in its source.
  private static func append(
    _ example: CogLintFixtureExample,
    note: String?,
    to lines: inout [String]
  ) {
    let fence = String(repeating: "`", count: max(3, longestBacktickRun(in: example.source) + 1))
    lines.append("### \(example.name)")
    lines.append("")
    lines.append(example.explanation)
    lines.append("")
    if let note {
      lines.append(note)
      lines.append("")
    }
    lines.append("\(fence)swift")
    lines.append(
      example.source.hasSuffix("\n") ? String(example.source.dropLast()) : example.source)
    lines.append(fence)
    lines.append("")
  }

  /// Finds the longest Markdown-fence-like backtick run in arbitrary source.
  private static func longestBacktickRun(in source: String) -> Int {
    var longest = 0
    var current = 0
    for character in source {
      if character == "`" {
        current += 1
        longest = max(longest, current)
      } else {
        current = 0
      }
    }
    return longest
  }

  /// Formats exact positions compactly for both failures and generated docs.
  private static func describe(_ positions: [CogLintFixturePosition]) -> String {
    positions.map { "\($0.line):\($0.column)" }.joined(separator: ", ")
  }

  /// Makes names unambiguous without imposing Markdown syntax on failures.
  private static func quoted(_ value: String) -> String {
    "\u{201c}\(value)\u{201d}"
  }
}
