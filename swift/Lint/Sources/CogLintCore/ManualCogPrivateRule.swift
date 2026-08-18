import Foundation
import SwiftSyntax

/// Requires every directly writable Cog source name to be file-owned.
package struct ManualCogPrivateRule: CogLintRule {
  /// The stable identifier printed by every finding and suppression.
  package let slug = "manual-cog-private"

  /// The permanent native DocC article route settled for this rule.
  package let helpURL = URL(
    string: "https://skeswa.github.io/cog/documentation/cog/manualcogprivate"
  )!

  /// Creates the stateless production rule.
  package init() {}

  /// Reports each recognized direct manual source without declaration privacy.
  package func violations(
    in source: SourceFileSyntax,
    context _: CogLintRuleContext
  ) -> [CogLintViolation] {
    CogDeclarationClassifier.classify(in: source).compactMap { classification in
      guard classification.isWritableSource,
        !hasPrivateDeclarationAccess(classification.declaration)
      else {
        return nil
      }
      return CogLintViolation(
        message:
          "writable Cog sources must be `private` or `fileprivate`; expose `.readOnly` or a derived cog",
        at: classification.nameToken
      )
    }
  }
}

/// Whether a declaration has bare `private` or `fileprivate` access.
///
/// A modifier such as `private(set)` narrows only mutation and therefore does
/// not satisfy source-name privacy.
private func hasPrivateDeclarationAccess(_ declaration: VariableDeclSyntax) -> Bool {
  declaration.modifiers.contains { modifier in
    modifier.detail == nil
      && (modifier.name.text == "private" || modifier.name.text == "fileprivate")
  }
}
