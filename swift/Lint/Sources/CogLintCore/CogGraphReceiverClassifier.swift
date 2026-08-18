import SwiftSyntax

/// The syntax role that proves an identifier is a Cog graph capability.
package enum CogGraphReceiverKind: Equatable, Sendable {
  /// A view property bound by `@Environment(\.cogs)`.
  case environmentCogs

  /// A selector's inferred or explicitly typed reader.
  case selectorReader

  /// A tracked reaction's inferred or explicitly typed reader.
  case reactionReader

  /// A commit closure's inferred or explicitly typed writer.
  case writer

  /// A mechanism `operate` parameter or `whenever` child controller.
  case mechanismController

  /// A local bound directly from `Cogs.bootstrapApp(...)`.
  case bootstrapCogs
}

/// A lexical syntax boundary in which one receiver binding is visible.
package struct CogLexicalScope: Sendable {
  /// The function, closure, code block, or member block that owns the binding.
  private let syntax: Syntax

  /// Creates a scope around one owning syntax node.
  package init(_ syntax: some SyntaxProtocol) {
    self.syntax = Syntax(syntax)
  }

  /// Whether `node` is the scope itself or one of its descendants.
  package func contains(_ node: some SyntaxProtocol) -> Bool {
    var cursor: Syntax? = Syntax(node)
    while let current = cursor {
      if current.id == syntax.id { return true }
      cursor = current.parent
    }
    return false
  }
}

/// One identifier proven by written syntax to be a graph receiver.
package struct CogGraphReceiverClassification: Sendable {
  /// The binding token used for name matching and diagnostic positions.
  package let nameToken: TokenSyntax

  /// The syntax evidence that established this capability.
  package let kind: CogGraphReceiverKind

  /// The exact lexical region where this binding may be referenced.
  package let scope: CogLexicalScope

  /// The receiver's source spelling without trivia.
  package var name: String { nameToken.text }

  /// Creates one scoped receiver classification.
  package init(
    nameToken: TokenSyntax,
    kind: CogGraphReceiverKind,
    scope: CogLexicalScope
  ) {
    self.nameToken = nameToken
    self.kind = kind
    self.scope = scope
  }
}

/// Recognizes conventional Cog receivers without type checking or data flow.
package enum CogGraphReceiverClassifier {
  /// Classifies environment and typed bindings, bootstrap locals, and inferred closures.
  package static func classify(in source: SourceFileSyntax) -> [CogGraphReceiverClassification] {
    let baseVisitor = CogBaseReceiverVisitor()
    baseVisitor.walk(source)
    var classifications = baseVisitor.classifications

    appendSelectorReceivers(in: source, to: &classifications)

    let callVisitor = CogCallReceiverVisitor(baseReceivers: classifications)
    callVisitor.walk(source)
    classifications.append(contentsOf: callVisitor.classifications)

    var byPosition: [Int: CogGraphReceiverClassification] = [:]
    for classification in classifications {
      byPosition[classification.nameToken.positionAfterSkippingLeadingTrivia.utf8Offset] =
        classification
    }
    return byPosition.values.sorted {
      $0.nameToken.positionAfterSkippingLeadingTrivia
        < $1.nameToken.positionAfterSkippingLeadingTrivia
    }
  }

  /// Derives selector readers from declarations so annotation-dependent `.init` is covered.
  private static func appendSelectorReceivers(
    in source: SourceFileSyntax,
    to classifications: inout [CogGraphReceiverClassification]
  ) {
    for declaration in CogDeclarationClassifier.classify(in: source)
    where declaration.access == .direct && declaration.origin != .writableSource {
      guard let call = declaration.binding.initializer?.value.as(FunctionCallExprSyntax.self),
        let closure = primaryClosure(of: call),
        let token = closureParameterTokens(in: closure).first(where: { $0.text == "c" })
      else {
        continue
      }
      classifications.append(
        CogGraphReceiverClassification(
          nameToken: token,
          kind: .selectorReader,
          scope: CogLexicalScope(closure)
        )
      )
    }
  }
}

/// Finds bindings whose own written syntax establishes graph capability.
private final class CogBaseReceiverVisitor: SyntaxVisitor {
  /// Base receivers collected in source order.
  fileprivate var classifications: [CogGraphReceiverClassification] = []

  /// Uses source-accurate tokens for stable lexical scopes and positions.
  init() {
    super.init(viewMode: .sourceAccurate)
  }

  /// Finds `@Environment(\.cogs) ... cogs` and direct bootstrap locals.
  override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
    if hasCogsEnvironmentAttribute(node),
      let memberBlock = nearestAncestor(MemberBlockSyntax.self, from: node)
    {
      for binding in node.bindings {
        guard let token = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier,
          token.text == "cogs"
        else {
          continue
        }
        classifications.append(
          CogGraphReceiverClassification(
            nameToken: token,
            kind: .environmentCogs,
            scope: CogLexicalScope(memberBlock)
          )
        )
      }
    }

    if let codeBlock = nearestAncestor(CodeBlockSyntax.self, from: node) {
      for binding in node.bindings {
        guard let token = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier,
          isDirectBootstrap(binding.initializer?.value)
        else {
          continue
        }
        classifications.append(
          CogGraphReceiverClassification(
            nameToken: token,
            kind: .bootstrapCogs,
            scope: CogLexicalScope(codeBlock)
          )
        )
      }
    }
    return .visitChildren
  }

  /// Finds explicitly typed graph capabilities in function parameters.
  override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
    for parameter in node.signature.parameterClause.parameters {
      guard let kind = receiverKind(forType: parameter.type),
        let token = parameter.secondName ?? nonUnderscore(parameter.firstName)
      else {
        continue
      }
      classifications.append(
        CogGraphReceiverClassification(
          nameToken: token,
          kind: kind,
          scope: CogLexicalScope(node)
        )
      )
    }
    return .visitChildren
  }

  /// Finds explicitly typed graph capabilities in closure parameters.
  override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
    guard case .parameterClause(let clause) = node.signature?.parameterClause else {
      return .visitChildren
    }
    for parameter in clause.parameters {
      guard let type = parameter.type,
        let kind = receiverKind(forType: type),
        let token = parameter.secondName ?? nonUnderscore(parameter.firstName)
      else {
        continue
      }
      classifications.append(
        CogGraphReceiverClassification(
          nameToken: token,
          kind: kind,
          scope: CogLexicalScope(node)
        )
      )
    }
    return .visitChildren
  }
}

/// Infers conventional closure parameters from calls on already-scoped capabilities.
private final class CogCallReceiverVisitor: SyntaxVisitor {
  /// Environment, typed, bootstrap, and selector receivers available for call matching.
  private var baseReceivers: [CogGraphReceiverClassification]

  /// Inferred call-body receivers collected in source order.
  fileprivate var classifications: [CogGraphReceiverClassification] = []

  /// Creates a call pass over the first-pass lexical receiver inventory.
  init(baseReceivers: [CogGraphReceiverClassification]) {
    self.baseReceivers = baseReceivers
    super.init(viewMode: .sourceAccurate)
  }

  /// Recognizes `commit`, mechanism `run`, and mechanism `whenever` closures.
  override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
    guard let member = node.calledExpression.as(MemberAccessExprSyntax.self),
      let baseName = receiverBaseName(member.base),
      let base = baseReceivers.last(where: {
        $0.name == baseName && $0.scope.contains(node)
      }),
      let closure = primaryClosure(of: node)
    else {
      return .visitChildren
    }

    let method = member.declName.baseName.text
    let kind: CogGraphReceiverKind
    let token: TokenSyntax?
    switch method {
    case "commit":
      kind = .writer
      token = closureParameterTokens(in: closure).first(where: { $0.text == "c" })
    case "run" where base.kind == .mechanismController:
      kind = .reactionReader
      token = closureParameterTokens(in: closure).first(where: { $0.text == "c" })
    case "whenever" where base.kind == .mechanismController:
      kind = .mechanismController
      token = closureParameterTokens(in: closure).first
    default:
      return .visitChildren
    }

    if let token, token.text != "_" {
      let classification = CogGraphReceiverClassification(
        nameToken: token,
        kind: kind,
        scope: CogLexicalScope(closure)
      )
      classifications.append(classification)
      baseReceivers.append(classification)
    }
    return .visitChildren
  }
}

/// Whether a declaration spells the exact Cog environment key-path attribute.
private func hasCogsEnvironmentAttribute(_ declaration: VariableDeclSyntax) -> Bool {
  for element in declaration.attributes {
    guard let attribute = element.as(AttributeSyntax.self),
      lastNominalName(in: attribute.attributeName) == "Environment"
    else {
      continue
    }
    let compact = attribute.trimmedDescription.filter { !$0.isWhitespace }
    if compact.hasSuffix("Environment(\\.cogs)") { return true }
  }
  return false
}

/// Whether an initializer is a direct `Cogs.bootstrapApp(...)` call.
private func isDirectBootstrap(_ expression: ExprSyntax?) -> Bool {
  guard let call = expression?.as(FunctionCallExprSyntax.self),
    let access = call.calledExpression.as(MemberAccessExprSyntax.self),
    access.declName.baseName.text == "bootstrapApp",
    receiverBaseName(access.base) == "Cogs"
  else {
    return false
  }
  return true
}

/// Maps only written capability types that rules may safely trust.
private func receiverKind(forType type: TypeSyntax) -> CogGraphReceiverKind? {
  switch lastNominalName(in: type) {
  case "Reader": return .selectorReader
  case "ReactionReader": return .reactionReader
  case "Writer": return .writer
  case "MechanismController": return .mechanismController
  default: return nil
  }
}

/// Extracts the final nominal name through qualification and common wrappers.
private func lastNominalName(in type: TypeSyntax) -> String? {
  if let identifier = type.as(IdentifierTypeSyntax.self) { return identifier.name.text }
  if let member = type.as(MemberTypeSyntax.self) { return member.name.text }
  if let optional = type.as(OptionalTypeSyntax.self) {
    return lastNominalName(in: optional.wrappedType)
  }
  if let attributed = type.as(AttributedTypeSyntax.self) {
    return lastNominalName(in: attributed.baseType)
  }
  return nil
}

/// Finds the nearest ancestor of one concrete syntax type.
private func nearestAncestor<Node: SyntaxProtocol>(
  _ type: Node.Type,
  from node: some SyntaxProtocol
) -> Node? {
  var cursor = Syntax(node).parent
  while let current = cursor {
    if let match = current.as(Node.self) { return match }
    cursor = current.parent
  }
  return nil
}

/// Returns a parameter token unless it is the external-only underscore spelling.
private func nonUnderscore(_ token: TokenSyntax) -> TokenSyntax? {
  token.text == "_" ? nil : token
}

/// Finds the semantic local name of a direct or `self`-qualified receiver expression.
private func receiverBaseName(_ expression: ExprSyntax?) -> String? {
  if let reference = expression?.as(DeclReferenceExprSyntax.self) {
    return reference.baseName.text
  }
  if let member = expression?.as(MemberAccessExprSyntax.self) {
    return member.declName.baseName.text
  }
  return nil
}

/// Selects the trailing closure, or the first unlabeled direct closure argument.
private func primaryClosure(of call: FunctionCallExprSyntax) -> ClosureExprSyntax? {
  if let trailing = call.trailingClosure { return trailing }
  for argument in call.arguments where argument.label == nil {
    if let closure = argument.expression.as(ClosureExprSyntax.self) { return closure }
  }
  return nil
}

/// Extracts simple or parenthesized closure parameter binding tokens.
private func closureParameterTokens(in closure: ClosureExprSyntax) -> [TokenSyntax] {
  guard let clause = closure.signature?.parameterClause else { return [] }
  switch clause {
  case .simpleInput(let parameters):
    return parameters.map(\.name)
  case .parameterClause(let parameters):
    return parameters.parameters.compactMap { parameter in
      parameter.secondName ?? nonUnderscore(parameter.firstName)
    }
  }
}
