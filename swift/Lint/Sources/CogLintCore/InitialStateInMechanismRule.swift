import Foundation
import SwiftSyntax

/// Keeps post-assembly initial graph work inside assembly-registered mechanisms.
package struct InitialStateInMechanismRule: CogLintRule {
  /// The stable identifier printed by every finding and suppression.
  package let slug = "initial-state-in-mechanism"

  /// The permanent native DocC article route settled for this rule.
  package let helpURL = URL(
    string: "https://skeswa.github.io/cog/documentation/cog/initialstateinmechanism"
  )!

  /// Creates the stateless production rule.
  package init() {}

  /// Reports every non-retention use of a directly assembled local in app initializers.
  package func violations(
    in source: SourceFileSyntax,
    context _: CogLintRuleContext
  ) -> [CogLintViolation] {
    let assemblyLocals = CogGraphReceiverClassifier.classify(in: source).filter {
      $0.kind == .assembledCogs
    }
    return CogAppEntryClassifier.classify(in: source).flatMap { app in
      app.memberBlocks.flatMap { members in
        members.members.flatMap { item -> [CogLintViolation] in
          guard let initializer = item.decl.as(InitializerDeclSyntax.self),
            let body = initializer.body
          else { return [] }
          let locals = assemblyLocals.filter { local in
            isDescendant(local.nameToken, of: initializer)
          }
          guard !locals.isEmpty else { return [] }
          let visitor = AssemblyLocalUseVisitor(locals: locals)
          visitor.walk(body)
          return visitor.violations
        }
      }
    }
  }
}

/// Finds forbidden references to directly assembled locals in one app initializer.
private final class AssemblyLocalUseVisitor: SyntaxVisitor {
  /// Direct assembly bindings whose lexical scopes intersect this initializer.
  private let locals: [CogGraphReceiverClassification]

  /// Findings retained in source traversal order.
  fileprivate var violations: [CogLintViolation] = []

  /// Creates a source-accurate reference traversal.
  init(locals: [CogGraphReceiverClassification]) {
    self.locals = locals
    super.init(viewMode: .sourceAccurate)
  }

  /// Rejects an assembly-local reference unless it is the direct retention value.
  override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
    guard
      let local = locals.reversed().first(where: {
        $0.name == node.baseName.text
          && $0.nameToken.positionAfterSkippingLeadingTrivia
            < node.baseName.positionAfterSkippingLeadingTrivia
          && $0.scope.contains(node)
      })
    else {
      return .visitChildren
    }
    guard !isRetentionReference(node, localName: local.name) else { return .visitChildren }
    violations.append(
      CogLintViolation(
        message:
          "`\(local.name)` may only retain the result of `Cogs.assemble`; move initial graph work into an assembly mechanism",
        at: node.baseName
      )
    )
    return .visitChildren
  }
}

/// Whether one reference is the direct value in a recognized app-runtime assignment.
private func isRetentionReference(
  _ reference: DeclReferenceExprSyntax,
  localName: String
) -> Bool {
  guard let sequence = nearestAssignmentSequence(from: reference),
    sequence.elements.count == 3,
    sequence.elements[sequence.elements.index(after: sequence.elements.startIndex)]
      .is(AssignmentExprSyntax.self)
  else {
    return false
  }
  let left = sequence.elements[sequence.elements.startIndex]
  let right = sequence.elements[sequence.elements.index(before: sequence.elements.endIndex)]
  guard let target = retentionTargetName(in: left) else { return false }

  if target == "cogs", isDirectReference(right, to: reference), target != localName {
    return true
  }
  if target == "cogs", isSelfMember(left), isDirectReference(right, to: reference) {
    return true
  }
  guard target == "_cogs", let call = right.as(FunctionCallExprSyntax.self),
    let calledName = finalCalledName(in: call.calledExpression),
    calledName == "State" || calledName == "init"
  else {
    return false
  }
  return call.arguments.contains { argument in
    argument.label?.text == "initialValue" && isDirectReference(argument.expression, to: reference)
  }
}

/// Finds the nearest parser sequence that structurally represents an assignment.
private func nearestAssignmentSequence(
  from node: some SyntaxProtocol
) -> SequenceExprSyntax? {
  var cursor = Syntax(node).parent
  while let current = cursor {
    if let sequence = current.as(SequenceExprSyntax.self),
      sequence.elements.contains(where: { $0.is(AssignmentExprSyntax.self) })
    {
      return sequence
    }
    cursor = current.parent
  }
  return nil
}

/// Extracts a bare or `self`-qualified assignment destination name.
private func retentionTargetName(in expression: ExprSyntax) -> String? {
  if let reference = expression.as(DeclReferenceExprSyntax.self) {
    return reference.baseName.text
  }
  if let member = expression.as(MemberAccessExprSyntax.self), isSelfMember(expression) {
    return member.declName.baseName.text
  }
  return nil
}

/// Whether an expression is a direct member access on `self`.
private func isSelfMember(_ expression: ExprSyntax) -> Bool {
  guard let member = expression.as(MemberAccessExprSyntax.self),
    let base = member.base?.as(DeclReferenceExprSyntax.self)
  else {
    return false
  }
  return base.baseName.text == "self"
}

/// Whether an expression is exactly the reference node rather than an indirect use.
private func isDirectReference(
  _ expression: ExprSyntax,
  to reference: DeclReferenceExprSyntax
) -> Bool {
  expression.as(DeclReferenceExprSyntax.self)?.id == reference.id
}

/// Extracts the final called name through qualification and generic specialization.
private func finalCalledName(in expression: ExprSyntax) -> String? {
  if let reference = expression.as(DeclReferenceExprSyntax.self) {
    return reference.baseName.text
  }
  if let member = expression.as(MemberAccessExprSyntax.self) {
    return member.declName.baseName.text
  }
  if let generic = expression.as(GenericSpecializationExprSyntax.self) {
    return finalCalledName(in: generic.expression)
  }
  return nil
}

/// Whether one syntax node is lexically nested under another.
private func isDescendant(
  _ node: some SyntaxProtocol,
  of ancestor: some SyntaxProtocol
) -> Bool {
  var cursor: Syntax? = Syntax(node)
  let ancestorID = Syntax(ancestor).id
  while let current = cursor {
    if current.id == ancestorID { return true }
    cursor = current.parent
  }
  return false
}
