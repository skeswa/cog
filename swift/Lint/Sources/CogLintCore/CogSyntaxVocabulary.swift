import SwiftSyntax

// The syntax micro-vocabulary shared by the classifiers and the rules.
//
// Every rule reads the same few written shapes — a final nominal name behind
// sugar, the nearest enclosing declaration, a graph-read spelling — and each
// used to carry its own private half-implementation of them. Concentrating the
// vocabulary here means a new rule spells "nearest enclosing extension" once,
// correctly, and a new public read spelling in Cog is one edit here rather
// than one per rule.

// MARK: - Nominal names

/// Extracts the final nominal component of a type through common wrappers.
///
/// Sees through optional sugar (`T?`, `T!`), attributed types
/// (`@MainActor T`), opaque and existential markers (`some T`, `any T`), and
/// takes the last member component of a qualified spelling (`A.B.C` gives
/// `C`) without requiring the base itself to be nominal. Rules use this when
/// only the innermost conventional name matters — an extension target, a
/// return type, or a capability parameter — because none of those wrappers
/// changes which convention applies. Generic arguments are ignored rather
/// than followed.
package func finalNominalName(in type: TypeSyntax) -> String? {
  if let identifier = type.as(IdentifierTypeSyntax.self) { return identifier.name.text }
  if let member = type.as(MemberTypeSyntax.self) { return member.name.text }
  if let optional = type.as(OptionalTypeSyntax.self) {
    return finalNominalName(in: optional.wrappedType)
  }
  if let optional = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
    return finalNominalName(in: optional.wrappedType)
  }
  if let attributed = type.as(AttributedTypeSyntax.self) {
    return finalNominalName(in: attributed.baseType)
  }
  if let someOrAny = type.as(SomeOrAnyTypeSyntax.self) {
    return finalNominalName(in: someOrAny.constraint)
  }
  return nil
}

/// Extracts the final nominal component of a callee or member-base expression.
///
/// Sees through qualification (`A.B` gives `B`) and generic specialization
/// (`Cog<Int>` gives `Cog`). Only reference and member spellings qualify: a
/// call, literal, or other computed base names no type this syntax-only pass
/// can trust, and yields `nil`.
package func finalNominalName(in expression: ExprSyntax) -> String? {
  if let reference = expression.as(DeclReferenceExprSyntax.self) {
    return reference.baseName.text
  }
  if let member = expression.as(MemberAccessExprSyntax.self) {
    return member.declName.baseName.text
  }
  if let generic = expression.as(GenericSpecializationExprSyntax.self) {
    return finalNominalName(in: generic.expression)
  }
  return nil
}

/// Extracts a qualification-preserving nominal path, ignoring generic arguments.
///
/// Unlike the final-name extractors, every component must be nominal:
/// `A.B.C` yields `["A", "B", "C"]`, while a member whose base is an array,
/// tuple, or other structural type yields `nil`, because a partial path would
/// misname the type it came from. Classifiers use this where qualification is
/// identity — joining a type's same-file extensions to its declaration.
package func nominalPath(of type: TypeSyntax) -> [String]? {
  if let identifier = type.as(IdentifierTypeSyntax.self) {
    return [identifier.name.text]
  }
  if let member = type.as(MemberTypeSyntax.self), let base = nominalPath(of: member.baseType) {
    return base + [member.name.text]
  }
  return nil
}

// MARK: - Lexical neighborhood

/// Finds the nearest ancestor of one concrete syntax type, optionally filtered.
///
/// Walks parent links only, so the answer is lexical rather than semantic.
/// The filter lets a caller skip structurally similar ancestors — the nearest
/// sequence that actually contains an assignment, say — without hand-rolling
/// another cursor loop.
package func nearestAncestor<Node: SyntaxProtocol>(
  _ type: Node.Type,
  from node: some SyntaxProtocol,
  where isIncluded: (Node) -> Bool = { _ in true }
) -> Node? {
  var cursor = Syntax(node).parent
  while let current = cursor {
    if let match = current.as(Node.self), isIncluded(match) { return match }
    cursor = current.parent
  }
  return nil
}

// MARK: - Graph reads

/// Whether an expression spells the graph receiver itself.
///
/// Recognizes bare `self`, the bare `status` lens, a `status` lens chained on
/// another recognized base, and — through `orReceiver` — any identifier the
/// caller has classified as a scoped graph capability. Both read-shape rules
/// consume this recognizer, so a future public read spelling lands here once
/// rather than once per rule.
package func isGraphReceiverExpression(
  _ expression: ExprSyntax,
  orReceiver isReceiver: (DeclReferenceExprSyntax) -> Bool = { _ in false }
) -> Bool {
  if let reference = expression.as(DeclReferenceExprSyntax.self) {
    if reference.baseName.text == "self" || reference.baseName.text == "status" { return true }
    return isReceiver(reference)
  }
  guard let member = expression.as(MemberAccessExprSyntax.self),
    member.declName.baseName.text == "status",
    let base = member.base
  else {
    return false
  }
  return isGraphReceiverExpression(base, orReceiver: isReceiver)
}

/// The `peek` token of a callee that reads the graph without tracking.
///
/// Bare `peek` always qualifies; qualified `peek` qualifies when its base
/// satisfies `onGraphBase`. The exact token comes back so a diagnostic lands
/// on the untracked read itself rather than on the whole call.
package func directPeekToken(
  in callee: ExprSyntax,
  onGraphBase isGraphBase: (ExprSyntax) -> Bool
) -> TokenSyntax? {
  if let reference = callee.as(DeclReferenceExprSyntax.self),
    reference.baseName.text == "peek"
  {
    return reference.baseName
  }
  guard let member = callee.as(MemberAccessExprSyntax.self),
    member.declName.baseName.text == "peek",
    let base = member.base,
    isGraphBase(base)
  else {
    return nil
  }
  return member.declName.baseName
}

// MARK: - Receivers

/// Whether one written identifier resolves to a receiver in scope at that use.
///
/// Purely lexical: the name must match and the receiver's owning scope must
/// contain the mention. Callers that additionally need the matched receiver,
/// or an ordering constraint between binding and mention, keep their own
/// search over the same classifications.
package func isClassifiedReceiver(
  named name: String,
  at node: some SyntaxProtocol,
  among receivers: [CogGraphReceiverClassification]
) -> Bool {
  receivers.contains { receiver in
    receiver.name == name && receiver.scope.contains(node)
  }
}
