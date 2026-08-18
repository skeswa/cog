import SwiftSyntax

/// One same-file type recognized as a SwiftUI view.
package struct CogViewClassification: Sendable {
  /// The lexical nominal path used to join a primary declaration and extensions.
  package let qualifiedName: String

  /// Every same-file member block belonging to the recognized type.
  package let memberBlocks: [MemberBlockSyntax]

  /// Creates an aggregated view classification.
  package init(qualifiedName: String, memberBlocks: [MemberBlockSyntax]) {
    self.qualifiedName = qualifiedName
    self.memberBlocks = memberBlocks
  }
}

/// One same-file type recognized as a SwiftUI app entry point.
package struct CogAppEntryClassification: Sendable {
  /// The lexical nominal path used to join a primary declaration and extensions.
  package let qualifiedName: String

  /// Every same-file member block belonging to the recognized type.
  package let memberBlocks: [MemberBlockSyntax]

  /// Creates an aggregated app-entry classification.
  package init(qualifiedName: String, memberBlocks: [MemberBlockSyntax]) {
    self.qualifiedName = qualifiedName
    self.memberBlocks = memberBlocks
  }
}

/// Recognizes types with written `View` evidence in one source file.
package enum CogViewClassifier {
  /// Finds direct `View` conformances or an immediate `body: some View` property.
  ///
  /// Evidence from a same-file extension joins its primary declaration. A type
  /// whose only conformance is declared in another file remains intentionally
  /// invisible to this syntax-only pass.
  package static func classify(in source: SourceFileSyntax) -> [CogViewClassification] {
    let index = CogNominalIndex.build(from: source)
    return index.groups(where: \NominalPart.isView).map { group in
      CogViewClassification(qualifiedName: group.name, memberBlocks: group.memberBlocks)
    }
  }
}

/// Recognizes types with a written `App` conformance in one source file.
package enum CogAppEntryClassifier {
  /// Finds direct or same-file-extension `App` conformances.
  package static func classify(in source: SourceFileSyntax) -> [CogAppEntryClassification] {
    let index = CogNominalIndex.build(from: source)
    return index.groups(where: \NominalPart.isApp).map { group in
      CogAppEntryClassification(qualifiedName: group.name, memberBlocks: group.memberBlocks)
    }
  }
}

/// All declaration and extension fragments for one lexical nominal path.
private struct NominalGroup {
  /// The dot-separated path within this source file.
  let name: String

  /// Member blocks in source order across the primary declaration and extensions.
  let memberBlocks: [MemberBlockSyntax]
}

/// One nominal declaration or extension fragment and its written evidence.
private struct NominalPart {
  /// The lexical name used to join fragments.
  let name: String

  /// The fragment's immediate members.
  let memberBlock: MemberBlockSyntax

  /// Whether this fragment writes `View` or `body: some View` evidence.
  let isView: Bool

  /// Whether this fragment writes an `App` conformance.
  let isApp: Bool
}

/// A source-ordered same-file nominal index shared by view and app classifiers.
private struct CogNominalIndex {
  /// Every primary or extension fragment in source order.
  let parts: [NominalPart]

  /// Builds the index with one traversal so nested lexical names remain distinct.
  static func build(from source: SourceFileSyntax) -> CogNominalIndex {
    let visitor = CogNominalIndexVisitor()
    visitor.walk(source)
    return CogNominalIndex(parts: visitor.parts)
  }

  /// Aggregates every fragment whose name has at least one matching evidence part.
  func groups(where evidence: KeyPath<NominalPart, Bool>) -> [NominalGroup] {
    let recognized = Set(parts.filter { $0[keyPath: evidence] }.map(\.name))
    var orderedNames: [String] = []
    var blocksByName: [String: [MemberBlockSyntax]] = [:]
    for part in parts where recognized.contains(part.name) {
      if blocksByName[part.name] == nil { orderedNames.append(part.name) }
      blocksByName[part.name, default: []].append(part.memberBlock)
    }
    return orderedNames.map { name in
      NominalGroup(name: name, memberBlocks: blocksByName[name] ?? [])
    }
  }
}

/// Tracks lexical nominal names while collecting primary and extension fragments.
private final class CogNominalIndexVisitor: SyntaxVisitor {
  /// The containing nominal path for the node currently being visited.
  private var path: [String] = []

  /// Paths restored after visiting a file-scoped extension body.
  private var extensionParentPaths: [[String]] = []

  /// Collected fragments in lexical source order.
  fileprivate var parts: [NominalPart] = []

  /// Uses source-accurate traversal so member blocks remain suitable for diagnostics.
  init() {
    super.init(viewMode: .sourceAccurate)
  }

  /// Records and enters a structure declaration.
  override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
    enter(name: node.name.text, inheritance: node.inheritanceClause, members: node.memberBlock)
  }

  /// Leaves a structure declaration.
  override func visitPost(_ node: StructDeclSyntax) { path.removeLast() }

  /// Records and enters a class declaration.
  override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
    enter(name: node.name.text, inheritance: node.inheritanceClause, members: node.memberBlock)
  }

  /// Leaves a class declaration.
  override func visitPost(_ node: ClassDeclSyntax) { path.removeLast() }

  /// Records and enters an enum declaration.
  override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
    enter(name: node.name.text, inheritance: node.inheritanceClause, members: node.memberBlock)
  }

  /// Leaves an enum declaration.
  override func visitPost(_ node: EnumDeclSyntax) { path.removeLast() }

  /// Records and enters an actor declaration.
  override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
    enter(name: node.name.text, inheritance: node.inheritanceClause, members: node.memberBlock)
  }

  /// Leaves an actor declaration.
  override func visitPost(_ node: ActorDeclSyntax) { path.removeLast() }

  /// Records a same-file extension under the lexical type path it spells.
  override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
    extensionParentPaths.append(path)
    path = nominalPath(of: node.extendedType) ?? [node.extendedType.trimmedDescription]
    record(inheritance: node.inheritanceClause, members: node.memberBlock)
    return .visitChildren
  }

  /// Restores the surrounding path after an extension and its nested declarations.
  override func visitPost(_ node: ExtensionDeclSyntax) {
    path = extensionParentPaths.removeLast()
  }

  /// Skips local types because their identity and lifetime are not declaration surfaces.
  override func visit(_ node: CodeBlockSyntax) -> SyntaxVisitorContinueKind { .skipChildren }

  /// Records one nominal declaration and makes it the current lexical parent.
  private func enter(
    name: String,
    inheritance: InheritanceClauseSyntax?,
    members: MemberBlockSyntax
  ) -> SyntaxVisitorContinueKind {
    path.append(name)
    record(inheritance: inheritance, members: members)
    return .visitChildren
  }

  /// Captures written protocol and body-property evidence for the current path.
  private func record(
    inheritance: InheritanceClauseSyntax?,
    members: MemberBlockSyntax
  ) {
    let inheritedNames = Set(
      inheritance?.inheritedTypes.compactMap { nominalPath(of: $0.type)?.last } ?? [])
    parts.append(
      NominalPart(
        name: path.joined(separator: "."),
        memberBlock: members,
        isView: inheritedNames.contains("View") || hasSomeViewBody(in: members),
        isApp: inheritedNames.contains("App")
      )
    )
  }
}

/// Whether immediate members contain a `body` property written as `some View`.
private func hasSomeViewBody(in members: MemberBlockSyntax) -> Bool {
  for item in members.members {
    guard let variable = item.decl.as(VariableDeclSyntax.self) else { continue }
    for binding in variable.bindings {
      guard binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == "body",
        let someType = binding.typeAnnotation?.type.as(SomeOrAnyTypeSyntax.self),
        someType.someOrAnySpecifier.text == "some",
        nominalPath(of: someType.constraint)?.last == "View"
      else {
        continue
      }
      return true
    }
  }
  return false
}

/// Extracts a qualification-preserving nominal path while ignoring generic arguments.
private func nominalPath(of type: TypeSyntax) -> [String]? {
  if let identifier = type.as(IdentifierTypeSyntax.self) {
    return [identifier.name.text]
  }
  if let member = type.as(MemberTypeSyntax.self), let base = nominalPath(of: member.baseType) {
    return base + [member.name.text]
  }
  return nil
}
