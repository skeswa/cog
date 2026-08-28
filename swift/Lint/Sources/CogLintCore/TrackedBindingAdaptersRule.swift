import Foundation
import SwiftSyntax

/// Keeps SwiftUI bindings over graph state tracked and in one adapter place.
///
/// Cog vends no binding helper, so every `Binding` over graph state is an app's
/// own adapter. The convention gives that adapter exactly one shape and exactly
/// one home: a member of `extension Cogs`, whose getter reads trackably and
/// whose setter calls a named op. Two failures cost an app something a compiler
/// cannot return. A getter that reads through `peek` registers no dependency,
/// so the control renders once and then silently stops following the fact it
/// displays. A binding constructed inline in a view spreads the writable
/// surface across the view layer. Then no single file defines what the system
/// may mutate, which defeats the purpose of collecting the adapters.
///
/// The two checks divide by where the construction sits, so one binding never
/// reports both: a construction inside a recognized view is a placement
/// finding, and every other construction is checked for an untracked getter.
package struct TrackedBindingAdaptersRule: CogLintRule {
  /// The stable identifier printed by every finding and suppression.
  package let slug = "tracked-binding-adapters"

  /// The permanent native DocC article route settled for this rule.
  package let helpURL = URL(
    string: "https://skeswa.github.io/cog/documentation/cog/trackedbindingadapters"
  )!

  /// Creates the stateless production rule.
  package init() {}

  /// Reports view-local graph bindings and untracked binding getters.
  ///
  /// Both roles are checked in app and test views. A test that needs an
  /// untracked getter can use a next-line suppression.
  package func violations(
    in source: SourceFileSyntax,
    context _: CogLintRuleContext
  ) -> [CogLintViolation] {
    let viewMemberBlockIDs = Set(
      CogViewClassifier.classify(in: source).flatMap { $0.memberBlocks.map(\.id) }
    )
    let visitor = BindingConstructionVisitor(
      viewMemberBlockIDs: viewMemberBlockIDs,
      receivers: CogGraphReceiverClassifier.classify(in: source)
    )
    visitor.walk(source)
    return visitor.violations
  }
}

/// Traverses `Binding(get:set:)` constructions and applies the placement split.
private final class BindingConstructionVisitor: SyntaxVisitor {
  /// Member blocks belonging to types with written view evidence in this file.
  private let viewMemberBlockIDs: Set<SyntaxIdentifier>

  /// Every scoped graph capability recognized before construction analysis.
  private let receivers: [CogGraphReceiverClassification]

  /// Findings retained in source traversal order.
  fileprivate var violations: [CogLintViolation] = []

  /// Creates a source-accurate traversal over both classifier inventories.
  init(viewMemberBlockIDs: Set<SyntaxIdentifier>, receivers: [CogGraphReceiverClassification]) {
    self.viewMemberBlockIDs = viewMemberBlockIDs
    self.receivers = receivers
    super.init(viewMode: .sourceAccurate)
  }

  /// Classifies one explicit two-closure `Binding` construction.
  override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
    guard let nameToken = bindingConstructionToken(of: node),
      let getter = argumentClosure(labeled: "get", of: node)
    else {
      return .visitChildren
    }

    if isInsideRecognizedView(node) {
      if referencesClassifiedReceiver(in: node) {
        violations.append(
          CogLintViolation(
            message:
              "a `Binding` over graph state belongs in a `Cogs` extension adapter, not in a view; call the adapter from the view instead",
            at: nameToken
          )
        )
      }
      return .visitChildren
    }

    violations.append(contentsOf: untrackedGetterViolations(in: getter))
    return .visitChildren
  }

  /// Whether the nearest enclosing member block belongs to a recognized view.
  ///
  /// The nearest block rather than any ancestor block keeps a helper type
  /// nested inside a view from inheriting that view's placement policy.
  private func isInsideRecognizedView(_ node: some SyntaxProtocol) -> Bool {
    guard let members = nearestAncestor(MemberBlockSyntax.self, from: node) else { return false }
    return viewMemberBlockIDs.contains(members.id)
  }

  /// Whether any argument mentions a graph receiver visible at that mention.
  ///
  /// Mentioning the runtime is the evidence, not reading through it: the
  /// setter of a conforming adapter calls a named op and performs no read at
  /// all, and that call is exactly the writable surface this rule collects.
  private func referencesClassifiedReceiver(in call: FunctionCallExprSyntax) -> Bool {
    let visitor = ReceiverReferenceVisitor(receivers: receivers)
    visitor.walk(call)
    return visitor.foundReference
  }

  /// Reports each untracked read spelled inside one getter closure.
  private func untrackedGetterViolations(in getter: ClosureExprSyntax) -> [CogLintViolation] {
    let visitor = UntrackedReadVisitor(receivers: receivers)
    visitor.walk(getter)
    return visitor.tokens.map { token in
      CogLintViolation(
        message:
          "a binding getter must read trackably; `peek` registers no dependency, so the control stops following this value",
        at: token
      )
    }
  }
}

/// Finds any mention of a classified graph receiver within one expression.
private final class ReceiverReferenceVisitor: SyntaxVisitor {
  /// Receivers whose lexical scope is consulted for each candidate mention.
  private let receivers: [CogGraphReceiverClassification]

  /// Whether at least one in-scope receiver mention was reached.
  fileprivate var foundReference = false

  /// Creates a source-accurate scan over written identifiers.
  init(receivers: [CogGraphReceiverClassification]) {
    self.receivers = receivers
    super.init(viewMode: .sourceAccurate)
  }

  /// Matches an identifier against every receiver whose scope covers it.
  override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
    if isClassifiedReceiver(named: node.baseName.text, at: node, among: receivers) {
      foundReference = true
    }
    return .visitChildren
  }
}

/// Collects `peek` tokens that read the graph without registering a dependency.
private final class UntrackedReadVisitor: SyntaxVisitor {
  /// Receivers used to recognize a peek written on an environment runtime.
  private let receivers: [CogGraphReceiverClassification]

  /// Every untracked read token in source order.
  fileprivate var tokens: [TokenSyntax] = []

  /// Creates a source-accurate scan over written calls.
  init(receivers: [CogGraphReceiverClassification]) {
    self.receivers = receivers
    super.init(viewMode: .sourceAccurate)
  }

  /// Recognizes bare, `self`-qualified, status-lens, and receiver-qualified peeks.
  override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
    let token = directPeekToken(in: node.calledExpression) { expression in
      isGraphReceiverExpression(expression) { reference in
        isClassifiedReceiver(named: reference.baseName.text, at: reference, among: receivers)
      }
    }
    if let token {
      tokens.append(token)
    }
    return .visitChildren
  }
}

/// Extracts the `Binding` token of an explicit construction, ignoring other calls.
///
/// Direct, module-qualified, generically specialized, and `.init` spellings all
/// name the type in source. A factory returning a binding names nothing this
/// pass can trust and stays outside the rule.
private func bindingConstructionToken(of call: FunctionCallExprSyntax) -> TokenSyntax? {
  bindingToken(in: call.calledExpression)
}

/// Resolves the written `Binding` token through the accepted callee spellings.
private func bindingToken(in expression: ExprSyntax) -> TokenSyntax? {
  if let reference = expression.as(DeclReferenceExprSyntax.self) {
    return reference.baseName.text == "Binding" ? reference.baseName : nil
  }
  if let specialization = expression.as(GenericSpecializationExprSyntax.self) {
    return bindingToken(in: specialization.expression)
  }
  if let member = expression.as(MemberAccessExprSyntax.self) {
    if member.declName.baseName.text == "init", let base = member.base {
      return bindingToken(in: base)
    }
    return member.declName.baseName.text == "Binding" ? member.declName.baseName : nil
  }
  return nil
}

/// Finds one labeled closure argument of a call.
private func argumentClosure(
  labeled label: String,
  of call: FunctionCallExprSyntax
) -> ClosureExprSyntax? {
  for argument in call.arguments where argument.label?.text == label {
    if let closure = argument.expression.as(ClosureExprSyntax.self) { return closure }
  }
  return nil
}
