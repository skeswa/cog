import Foundation
import SwiftSyntax

/// A syntax-only check that reports violations in one parsed Swift file.
///
/// Rules own semantic classification and messages, while the shared runner
/// owns parsing, suppression, source-location conversion, and reporting. The
/// `Sendable` contract lets later CLI work evaluate independent files in
/// parallel without making syntax traversal inside one rule concurrent.
package protocol CogLintRule: Sendable {
  /// The stable kebab-case identifier printed in diagnostics and help URLs.
  var slug: String { get }

  /// The permanent article URL that teaches the convention behind this rule.
  var helpURL: URL { get }

  /// Returns violations in deterministic source order for `source` and `context`.
  func violations(in source: SourceFileSyntax, context: CogLintRuleContext) -> [CogLintViolation]
}

/// The declared role of the target whose source files are being checked.
///
/// Role is invocation configuration, never inferred from path spelling. Most
/// rules behave identically in both roles; `primitives-only-in-ops` uses the
/// test role to permit direct graph driving in test targets.
package enum CogLintTargetRole: String, CaseIterable, Sendable {
  /// Application and library production source with every convention enabled.
  case production

  /// Test source with the explicitly documented primitive-call exemption.
  case test
}

/// Invocation-wide configuration visible to every syntax rule.
package struct CogLintRuleContext: Equatable, Sendable {
  /// Whether the selected files belong to a production or test target.
  package let targetRole: CogLintTargetRole

  /// Creates the rule context for one explicitly selected target role.
  package init(targetRole: CogLintTargetRole) {
    self.targetRole = targetRole
  }
}

/// The production rule set evaluated by the bare CLI and both plugin surfaces.
///
/// Rule tasks append their finished rule here. Keeping one registry in the core
/// prevents the CLI, command plugin, and build-tool plugin from silently
/// shipping different convention sets.
package enum CogLintRuleRegistry {
  /// The rules enabled for production targets, in stable registration order.
  package static let all: [any CogLintRule] = [
    CogDeclarationSuffixRule(),
    NoCogsInViewInitRule(),
    ManualCogPrivateRule(),
  ]
}

/// One rule violation before its absolute offset is mapped into a source file.
///
/// Retaining the parser's absolute position avoids deriving line and column in
/// every rule. The CLI and fixture harness each convert it against the exact
/// tree the rule inspected, so UTF-8 columns and `#sourceLocation` handling
/// cannot drift between production and tests.
package struct CogLintViolation: Equatable, Sendable {
  /// The diagnostic text specific to the violated convention.
  package let message: String

  /// The zero-based UTF-8 offset into the parsed source tree.
  package let position: AbsolutePosition

  /// Creates a violation at an already-selected absolute source position.
  package init(message: String, position: AbsolutePosition) {
    self.message = message
    self.position = position
  }

  /// Creates a violation at the first non-trivia byte of a syntax node.
  package init(message: String, at node: some SyntaxProtocol) {
    self.init(message: message, position: node.positionAfterSkippingLeadingTrivia)
  }
}
