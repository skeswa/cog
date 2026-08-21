import Foundation
import SwiftSyntax

/// Keeps graph mutation and refresh primitives behind named domain operations.
package struct PrimitivesOnlyInOpsRule: CogLintRule {
  /// The stable identifier printed by every finding and suppression.
  package let slug = "primitives-only-in-ops"

  /// The permanent native DocC article route settled for this rule.
  package let helpURL = URL(
    string: "https://skeswa.github.io/cog/documentation/cog/primitivesonlyinops"
  )!

  /// Creates the stateless production rule.
  package init() {}

  /// Reports production primitive calls outside their bare `CogOps` definition site.
  package func violations(
    in source: SourceFileSyntax,
    context: CogLintRuleContext
  ) -> [CogLintViolation] {
    guard context.targetRole == .production else { return [] }
    let visitor = PrimitiveCallVisitor(
      receivers: CogGraphReceiverClassifier.classify(in: source)
    )
    visitor.walk(source)
    return visitor.violations
  }
}

/// Traverses calls while joining receiver evidence to lexical extension context.
private final class PrimitiveCallVisitor: SyntaxVisitor {
  /// Every scoped graph capability recognized before call analysis.
  private let receivers: [CogGraphReceiverClassification]

  /// Findings retained in source traversal order.
  fileprivate var violations: [CogLintViolation] = []

  /// Creates a source-accurate call traversal over classifier output.
  init(receivers: [CogGraphReceiverClassification]) {
    self.receivers = receivers
    super.init(viewMode: .sourceAccurate)
  }

  /// Checks member calls on capabilities and bare calls in graph-runtime extensions.
  override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
    guard let call = primitiveCall(in: node) else { return .visitChildren }
    let extensionName = enclosingExtensionName(of: node)

    switch call.form {
    case .bare:
      if extensionName == "Cogs" {
        violations.append(violation(for: call.nameToken))
      }
    case .member(let receiverName):
      let hasClassifiedReceiver = receivers.reversed().contains { receiver in
        receiver.name == receiverName && receiver.scope.contains(node)
      }
      let isSelfOnPrimitiveExtension =
        receiverName == "self" && (extensionName == "Cogs" || extensionName == "CogOps")
      if hasClassifiedReceiver || isSelfOnPrimitiveExtension {
        violations.append(violation(for: call.nameToken))
      }
    }
    return .visitChildren
  }

  /// Builds the shared repair message at the primitive name rather than its receiver.
  private func violation(for token: TokenSyntax) -> CogLintViolation {
    CogLintViolation(
      message:
        "`\(token.text)` may be called only bare inside `extension CogOps`; wrap it in a named domain op",
      at: token
    )
  }
}

/// The syntactic form and method token of one `turn` or `refresh` call.
private struct PrimitiveCall {
  /// Whether the call is bare or names a direct receiver.
  enum Form {
    /// An unqualified primitive call.
    case bare

    /// A primitive call whose base resolves to this lexical identifier.
    case member(receiverName: String)
  }

  /// The exact primitive token used for the diagnostic position and message.
  let nameToken: TokenSyntax

  /// The receiver form that determines which lexical policy applies.
  let form: Form
}

/// Recognizes the two primitive call names and their direct receiver form.
private func primitiveCall(in call: FunctionCallExprSyntax) -> PrimitiveCall? {
  if let reference = call.calledExpression.as(DeclReferenceExprSyntax.self),
    isPrimitive(reference.baseName.text)
  {
    return PrimitiveCall(nameToken: reference.baseName, form: .bare)
  }
  guard let member = call.calledExpression.as(MemberAccessExprSyntax.self),
    isPrimitive(member.declName.baseName.text),
    let receiverName = directReceiverName(member.base)
  else {
    return nil
  }
  return PrimitiveCall(
    nameToken: member.declName.baseName,
    form: .member(receiverName: receiverName)
  )
}

/// Whether a call name is one of the two public graph-demand primitives.
private func isPrimitive(_ name: String) -> Bool {
  name == "turn" || name == "refresh"
}

/// Extracts an identifier from `receiver.method` or `self.receiver.method`.
private func directReceiverName(_ expression: ExprSyntax?) -> String? {
  if let reference = expression?.as(DeclReferenceExprSyntax.self) {
    return reference.baseName.text
  }
  if let member = expression?.as(MemberAccessExprSyntax.self) {
    return member.declName.baseName.text
  }
  return nil
}

/// Finds the nearest lexical extension and returns its final nominal component.
private func enclosingExtensionName(of node: some SyntaxProtocol) -> String? {
  var cursor = Syntax(node).parent
  while let current = cursor {
    if let declaration = current.as(ExtensionDeclSyntax.self) {
      return finalNominalName(in: declaration.extendedType)
    }
    cursor = current.parent
  }
  return nil
}

/// Extracts the final nominal component from an extension target.
private func finalNominalName(in type: TypeSyntax) -> String? {
  if let identifier = type.as(IdentifierTypeSyntax.self) { return identifier.name.text }
  if let member = type.as(MemberTypeSyntax.self) { return member.name.text }
  return nil
}
