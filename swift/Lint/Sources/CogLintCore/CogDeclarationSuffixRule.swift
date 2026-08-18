import Foundation
import SwiftSyntax

/// Requires every recognized Cog declaration name to expose its reference shape.
package struct CogDeclarationSuffixRule: CogLintRule {
  /// The stable identifier printed by every finding and suppression.
  package let slug = "cog-declaration-suffix"

  /// The permanent native DocC article route settled for this rule.
  package let helpURL = URL(
    string: "https://skeswa.github.io/cog/documentation/cog/cogdeclarationsuffix"
  )!

  /// Creates the stateless production rule.
  package init() {}

  /// Reports recognized declarations whose final suffix disagrees with their shape.
  package func violations(
    in source: SourceFileSyntax,
    context _: CogLintRuleContext
  ) -> [CogLintViolation] {
    CogDeclarationClassifier.classify(in: source).compactMap { classification in
      let expectedSuffix = classification.shape == .keyless ? "Cog" : "Cogs"
      guard !classification.name.hasSuffix(expectedSuffix) else { return nil }
      return CogLintViolation(
        message:
          "Cog declaration names must end in `\(expectedSuffix)` for this shape, with qualifiers before the suffix",
        at: classification.nameToken
      )
    }
  }
}
