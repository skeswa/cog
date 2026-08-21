import SwiftSyntax

/// Recognizes Cog value-reference declarations from written Swift syntax only.
package enum CogDeclarationClassifier {
  /// Classifies file- and type-scoped variable bindings in source order.
  ///
  /// The classifier intentionally skips executable code blocks. It follows a
  /// `.readOnly` base only when that unqualified name was already classified
  /// in the current or an enclosing lexical declaration scope; it never chases
  /// aliases, factories, assignments, later declarations, or other files.
  package static func classify(in source: SourceFileSyntax) -> [CogDeclarationClassification] {
    let visitor = CogDeclarationVisitor()
    visitor.walk(source)
    return visitor.classifications
  }
}

/// Mutable traversal state for the public value-type classifier boundary.
private final class CogDeclarationVisitor: SyntaxVisitor {
  /// One evidence table per file or member scope, outermost first.
  private var evidenceScopes: [[String: CogDeclarationEvidence]] = [[:]]

  /// Completed classifications in lexical source order.
  fileprivate var classifications: [CogDeclarationClassification] = []

  /// Uses source-accurate tokens because diagnostic positions retain trivia offsets.
  init() {
    super.init(viewMode: .sourceAccurate)
  }

  /// Starts an isolated type or extension member namespace.
  override func visit(_ node: MemberBlockSyntax) -> SyntaxVisitorContinueKind {
    evidenceScopes.append([:])
    return .visitChildren
  }

  /// Ends the member namespace after all nested declarations have been visited.
  override func visitPost(_ node: MemberBlockSyntax) {
    evidenceScopes.removeLast()
  }

  /// Skips locals, closure bodies, accessors, and nested local types by design.
  override func visit(_ node: CodeBlockSyntax) -> SyntaxVisitorContinueKind {
    .skipChildren
  }

  /// Classifies each identifier binding before later bindings may project it.
  override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
    for binding in node.bindings {
      guard let nameToken = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier,
        let evidence = classify(binding: binding)
      else {
        continue
      }

      classifications.append(
        CogDeclarationClassification(
          nameToken: nameToken,
          declaration: node,
          binding: binding,
          shape: evidence.shape,
          origin: evidence.origin,
          access: evidence.access
        )
      )
      evidenceScopes[evidenceScopes.count - 1][nameToken.text] = evidence
    }
    return .skipChildren
  }

  /// Combines the two written evidence channels for one initialized binding.
  private func classify(binding: PatternBindingSyntax) -> CogDeclarationEvidence? {
    guard let initializer = binding.initializer?.value else { return nil }
    let annotation = binding.typeAnnotation.flatMap { evidence(from: $0.type) }

    if let projection = projectionEvidence(from: initializer) {
      return annotation.map { projection.merged(with: $0) } ?? projection
    }
    guard let call = initializer.as(FunctionCallExprSyntax.self) else { return nil }
    if isDotInit(call.calledExpression) {
      return annotation
    }
    guard let calledName = nominalName(in: call.calledExpression),
      let called = CogDeclarationEvidence(nominalName: calledName)
    else {
      return nil
    }
    return annotation.map { called.merged(with: $0) } ?? called
  }

  /// Resolves an unqualified `.readOnly` base through already-classified scopes.
  private func projectionEvidence(from expression: ExprSyntax) -> CogDeclarationEvidence? {
    guard let access = expression.as(MemberAccessExprSyntax.self),
      access.declName.baseName.text == "readOnly",
      let base = access.base?.as(DeclReferenceExprSyntax.self),
      let source = lookup(base.baseName.text)
    else {
      return nil
    }
    return CogDeclarationEvidence(
      shape: source.shape,
      origin: source.origin,
      access: .readOnlyProjection
    )
  }

  /// Finds the nearest earlier declaration evidence visible by unqualified name.
  private func lookup(_ name: String) -> CogDeclarationEvidence? {
    for scope in evidenceScopes.reversed() {
      if let evidence = scope[name] { return evidence }
    }
    return nil
  }
}

/// Orthogonal facts recovered from one nominal spelling or projection.
private struct CogDeclarationEvidence {
  /// Whether the written reference is keyless or boxed.
  let shape: CogDeclarationShape

  /// The state origin preserved through projections.
  let origin: CogDeclarationOrigin

  /// Whether the binding directly names the origin or projects it.
  let access: CogDeclarationAccess

  /// Maps only Cog's six declarations and two read-only facade types.
  init?(nominalName: String) {
    switch nominalName {
    case "Cog":
      self.init(shape: .keyless, origin: .automatic, access: .direct)
    case "CogBox":
      self.init(shape: .box, origin: .automatic, access: .direct)
    case "ManualCog":
      self.init(shape: .keyless, origin: .writableSource, access: .direct)
    case "ManualCogBox":
      self.init(shape: .box, origin: .writableSource, access: .direct)
    case "AsyncCog":
      self.init(shape: .keyless, origin: .asynchronous, access: .direct)
    case "AsyncCogBox":
      self.init(shape: .box, origin: .asynchronous, access: .direct)
    case "CogProjection":
      self.init(shape: .keyless, origin: .writableSource, access: .readOnlyProjection)
    case "CogBoxProjection":
      self.init(shape: .box, origin: .writableSource, access: .readOnlyProjection)
    default:
      return nil
    }
  }

  /// Creates evidence already decomposed into its orthogonal classifier facts.
  init(
    shape: CogDeclarationShape,
    origin: CogDeclarationOrigin,
    access: CogDeclarationAccess
  ) {
    self.shape = shape
    self.origin = origin
    self.access = access
  }

  /// Merges compatible channels while retaining any box, writable, or projection evidence.
  func merged(with other: CogDeclarationEvidence) -> CogDeclarationEvidence {
    CogDeclarationEvidence(
      shape: shape == .box || other.shape == .box ? .box : .keyless,
      origin: mergedOrigin(with: other),
      access:
        access == .readOnlyProjection || other.access == .readOnlyProjection
        ? .readOnlyProjection : .direct
    )
  }

  /// Gives manual evidence precedence, then async, for impossible mismatched source spellings.
  private func mergedOrigin(with other: CogDeclarationEvidence) -> CogDeclarationOrigin {
    if origin == .writableSource || other.origin == .writableSource { return .writableSource }
    if origin == .asynchronous || other.origin == .asynchronous { return .asynchronous }
    return .automatic
  }
}

/// Extracts recognized nominal evidence through optional and parenthesized wrappers.
private func evidence(from type: TypeSyntax) -> CogDeclarationEvidence? {
  if let optional = type.as(OptionalTypeSyntax.self) {
    return evidence(from: optional.wrappedType)
  }
  if let optional = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
    return evidence(from: optional.wrappedType)
  }
  if let attributed = type.as(AttributedTypeSyntax.self) {
    return evidence(from: attributed.baseType)
  }
  if let tuple = type.as(TupleTypeSyntax.self), tuple.elements.count == 1,
    let element = tuple.elements.first
  {
    return evidence(from: element.type)
  }
  if let identifier = type.as(IdentifierTypeSyntax.self) {
    if identifier.name.text == "Optional",
      let argument = identifier.genericArgumentClause?.arguments.onlyElement,
      case .type(let wrapped) = argument.argument
    {
      return evidence(from: wrapped)
    }
    return CogDeclarationEvidence(nominalName: identifier.name.text)
  }
  if let member = type.as(MemberTypeSyntax.self) {
    if member.name.text == "Optional",
      let argument = member.genericArgumentClause?.arguments.onlyElement,
      case .type(let wrapped) = argument.argument
    {
      return evidence(from: wrapped)
    }
    return CogDeclarationEvidence(nominalName: member.name.text)
  }
  return nil
}

/// Extracts the final nominal callee through generic specialization and qualification.
private func nominalName(in expression: ExprSyntax) -> String? {
  if let reference = expression.as(DeclReferenceExprSyntax.self) {
    return reference.baseName.text
  }
  if let member = expression.as(MemberAccessExprSyntax.self) {
    return member.declName.baseName.text
  }
  if let generic = expression.as(GenericSpecializationExprSyntax.self) {
    return nominalName(in: generic.expression)
  }
  return nil
}

/// Whether a call uses the annotation-dependent `.init(...)` spelling.
private func isDotInit(_ expression: ExprSyntax) -> Bool {
  guard let member = expression.as(MemberAccessExprSyntax.self) else { return false }
  return member.base == nil && member.declName.baseName.text == "init"
}

/// A single-element collection value without silently accepting multiple generic arguments.
extension Collection {
  /// The only element when `count == 1`, otherwise `nil`.
  fileprivate var onlyElement: Element? {
    guard count == 1 else { return nil }
    return first
  }
}
