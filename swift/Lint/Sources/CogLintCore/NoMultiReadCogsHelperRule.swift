import Foundation
import SwiftSyntax

/// Prevents graph extensions from hiding several reads behind one value helper.
package struct NoMultiReadCogsHelperRule: CogLintRule {
  /// The stable identifier printed by every finding and suppression.
  package let slug = "no-multi-read-cogs-helper"

  /// The permanent native DocC article route settled for this rule.
  package let helpURL = URL(
    string: "https://skeswa.github.io/cog/documentation/cog/nomultireadcogshelper"
  )!

  /// Creates the stateless production rule.
  package init() {}

  /// Reports value helpers in exact `Cogs` or `CogOps` extensions with multiple reads.
  package func violations(
    in source: SourceFileSyntax,
    context _: CogLintRuleContext
  ) -> [CogLintViolation] {
    let visitor = MultiReadExtensionVisitor()
    visitor.walk(source)
    return visitor.violations
  }
}

/// Finds exact graph extensions and evaluates each immediate value member.
private final class MultiReadExtensionVisitor: SyntaxVisitor {
  /// Findings retained in source and member order.
  fileprivate var violations: [CogLintViolation] = []

  /// Uses source-accurate nodes for stable member diagnostic positions.
  init() {
    super.init(viewMode: .sourceAccurate)
  }

  /// Analyzes one graph extension without recursively treating its implementation as declarations.
  override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
    guard let name = finalNominalName(in: node.extendedType),
      name == "Cogs" || name == "CogOps"
    else {
      return .visitChildren
    }
    violations.append(contentsOf: memberViolations(in: node.memberBlock))
    return .skipChildren
  }
}

/// Produces at most one finding for each eligible immediate extension member.
private func memberViolations(in members: MemberBlockSyntax) -> [CogLintViolation] {
  members.members.flatMap { item -> [CogLintViolation] in
    if let function = item.decl.as(FunctionDeclSyntax.self),
      let returnType = function.signature.returnClause?.type,
      let body = function.body
    {
      return violation(nameToken: function.name, returnType: returnType, body: body)
        .map { [$0] } ?? []
    }
    if let variable = item.decl.as(VariableDeclSyntax.self) {
      return variable.bindings.compactMap { binding in
        guard let nameToken = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier,
          let returnType = binding.typeAnnotation?.type,
          let body = binding.accessorBlock
        else {
          return nil
        }
        return violation(nameToken: nameToken, returnType: returnType, body: body)
      }
    }
    if let subscriptDeclaration = item.decl.as(SubscriptDeclSyntax.self),
      let body = subscriptDeclaration.accessorBlock
    {
      return violation(
        nameToken: subscriptDeclaration.subscriptKeyword,
        returnType: subscriptDeclaration.returnClause.type,
        body: body
      ).map { [$0] } ?? []
    }
    return []
  }
}

/// Builds one member finding when its written return and lexical read count qualify.
private func violation(
  nameToken: TokenSyntax,
  returnType: TypeSyntax,
  body: some SyntaxProtocol
) -> CogLintViolation? {
  guard isOrdinaryValueReturn(returnType) else { return nil }
  let counter = ImmediateGraphReadVisitor()
  counter.walk(body)
  guard counter.count >= 2 else { return nil }
  return CogLintViolation(
    message:
      "value-returning `Cogs` and `CogOps` helpers may contain at most one immediate graph read; read values flatly at the consumer",
    at: nameToken
  )
}

/// Counts direct graph reads while pruning every nested closure body.
private final class ImmediateGraphReadVisitor: SyntaxVisitor {
  /// The number of direct value, status, or peek expressions encountered.
  fileprivate var count = 0

  /// Uses the exact written tree because no type or data-flow evidence is admitted.
  init() {
    super.init(viewMode: .sourceAccurate)
  }

  /// Keeps reads inside a nested closure outside the immediate member body.
  override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
    .skipChildren
  }

  /// Counts `self[...]`, `status[...]`, and `self.status[...]` once each.
  override func visit(_ node: SubscriptCallExprSyntax) -> SyntaxVisitorContinueKind {
    if isGraphReceiverExpression(node.calledExpression) {
      count += 1
    }
    return .visitChildren
  }

  /// Counts bare or self-qualified `peek`, including the corresponding status lens.
  override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
    if directPeekToken(in: node.calledExpression, onGraphBase: { isGraphReceiverExpression($0) })
      != nil
    {
      count += 1
    }
    return .visitChildren
  }
}

/// Whether a return type is a value other than void, view construction, or binding projection.
private func isOrdinaryValueReturn(_ type: TypeSyntax) -> Bool {
  if let tuple = type.as(TupleTypeSyntax.self), tuple.elements.isEmpty { return false }
  guard let nominal = finalNominalName(in: type) else { return true }
  return nominal != "Void" && nominal != "View" && nominal != "Binding"
}
