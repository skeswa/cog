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

  /// Returns violations in deterministic source order for `source`.
  func violations(in source: SourceFileSyntax) -> [CogLintViolation]
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
