import SwiftParser
import SwiftSyntax

/// Parses one Swift source buffer into the syntax tree shared by every lint rule.
///
/// Keeping parsing in the core target lets fixture tests and the executable use
/// the exact same swift-syntax entry point. The package access level keeps this
/// implementation seam out of CogLint's sole public product, the executable.
package enum CogLintParser {
  /// Parses `source` without invoking the Swift type checker or SourceKit.
  ///
  /// SwiftParser is intentionally error-tolerant: malformed input still
  /// produces a tree, allowing individual rules to decide whether they have
  /// enough written syntax to report a finding.
  package static func parse(source: String) -> SourceFileSyntax {
    Parser.parse(source: source)
  }
}
