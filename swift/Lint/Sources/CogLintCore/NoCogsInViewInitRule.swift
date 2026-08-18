import Foundation
import SwiftSyntax

/// Prevents a SwiftUI view from accepting or storing the app graph runtime.
package struct NoCogsInViewInitRule: CogLintRule {
  /// The stable identifier printed by every finding and suppression.
  package let slug = "no-cogs-in-view-init"

  /// The permanent native DocC article route settled for this rule.
  package let helpURL = URL(
    string: "https://skeswa.github.io/cog/documentation/cog/nocogsinviewinit"
  )!

  /// Creates the stateless production rule.
  package init() {}

  /// Reports written `Cogs` types on the forbidden immediate members of recognized views.
  package func violations(
    in source: SourceFileSyntax,
    context _: CogLintRuleContext
  ) -> [CogLintViolation] {
    CogViewClassifier.classify(in: source).flatMap { view in
      view.memberBlocks.flatMap(violations(in:))
    }
  }

  /// Checks stored properties, initializer parameters, and method parameters in one member block.
  private func violations(in members: MemberBlockSyntax) -> [CogLintViolation] {
    members.members.flatMap { item -> [CogLintViolation] in
      if let variable = item.decl.as(VariableDeclSyntax.self) {
        return variable.bindings.compactMap { binding in
          guard isStored(binding), let type = binding.typeAnnotation?.type else { return nil }
          return violation(in: type)
        }
      }
      if let initializer = item.decl.as(InitializerDeclSyntax.self) {
        return initializer.signature.parameterClause.parameters.compactMap { parameter in
          violation(in: parameter.type)
        }
      }
      if let function = item.decl.as(FunctionDeclSyntax.self) {
        return function.signature.parameterClause.parameters.compactMap { parameter in
          violation(in: parameter.type)
        }
      }
      return []
    }
  }

  /// Creates one declaration-level finding at the first written `Cogs` nominal token.
  private func violation(in type: TypeSyntax) -> CogLintViolation? {
    guard let token = type.tokens(viewMode: .sourceAccurate).first(where: { $0.text == "Cogs" })
    else { return nil }
    return CogLintViolation(
      message: "views must resolve `Cogs` with `@Environment(\\.cogs)`, not store or accept it",
      at: token
    )
  }
}

/// Whether a pattern binding stores state rather than computing it through accessors.
private func isStored(_ binding: PatternBindingSyntax) -> Bool {
  guard let accessorBlock = binding.accessorBlock else { return true }
  switch accessorBlock.accessors {
  case .getter:
    return false
  case .accessors(let accessors):
    return accessors.allSatisfy { accessor in
      accessor.accessorSpecifier.text == "willSet" || accessor.accessorSpecifier.text == "didSet"
    }
  }
}
