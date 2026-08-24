import Foundation
import SwiftSyntax

/// Requires underscored manual source names and exact `.readOnly` pairing.
///
/// The convention gives the published projection the clean domain name and
/// marks the file-owned writable source with a leading underscore, so the two
/// halves of one fact read as a pair: `private let _countCog = Cog.Manual { 0 }`
/// beside `let countCog = _countCog.readOnly`. An underscored source that is
/// never projected is accepted; not every source needs publication.
package struct ManualCogUnderscoreRule: CogLintRule {
  /// The stable identifier printed by every finding and suppression.
  package let slug = "manual-cog-underscore"

  /// The permanent native DocC article route settled for this rule.
  package let helpURL = URL(
    string: "https://skeswa.github.io/cog/documentation/cog/manualcogunderscore"
  )!

  /// Creates the stateless production rule.
  package init() {}

  /// Reports non-underscored manual sources and mispaired projections.
  ///
  /// The pairing check fires only when the classifier recorded the projected
  /// base identifier; annotation-only projections name no source and stay
  /// silent, consistent with the classifier's syntax-only evasions.
  package func violations(
    in source: SourceFileSyntax,
    context _: CogLintRuleContext
  ) -> [CogLintViolation] {
    CogDeclarationClassifier.classify(in: source).compactMap { classification in
      if classification.isWritableSource {
        guard !classification.name.hasPrefix("_") else { return nil }
        return CogLintViolation(
          message:
            "manual Cog declaration names must begin with `_`; publish the readable name as its `.readOnly` projection",
          at: classification.nameToken
        )
      }
      guard classification.access == .readOnlyProjection,
        let projectedSourceName = classification.projectedSourceName,
        projectedSourceName != "_" + classification.name
      else {
        return nil
      }
      return CogLintViolation(
        message:
          "a `.readOnly` projection named `\(classification.name)` must project a source named `_\(classification.name)`",
        at: classification.nameToken
      )
    }
  }
}
