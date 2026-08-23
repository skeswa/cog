import SwiftSyntax

/// Whether one recognized value reference names keyless or keyed state.
package enum CogDeclarationShape: Equatable, Sendable {
  /// One declaration names one graph value without a key.
  case keyless

  /// One box declaration produces keyed value references.
  case box
}

/// The semantic origin of state carried by a recognized declaration spelling.
///
/// Origin remains writable through a read-only projection so suffix and
/// documentation rules can understand its source, while ``CogDeclarationAccess``
/// separately prevents a projection from being treated as a writable name.
package enum CogDeclarationOrigin: Equatable, Sendable {
  /// Synchronous state computed from other graph values.
  case automatic

  /// Manually writable source state.
  case writableSource

  /// Asynchronously computed state with total value reads.
  case asynchronous
}

/// Whether a declaration directly names its origin or exposes a read-only facade.
package enum CogDeclarationAccess: Equatable, Sendable {
  /// A direct automatic, manual, or async declaration reference.
  case direct

  /// A `.readOnly` projection that cannot be passed to a writer.
  case readOnlyProjection
}

/// One variable binding recognized as a Cog value-reference declaration.
package struct CogDeclarationClassification: Sendable {
  /// The exact identifier token used for future diagnostic positioning.
  package let nameToken: TokenSyntax

  /// The containing declaration, including access modifiers shared by its bindings.
  package let declaration: VariableDeclSyntax

  /// The exact pattern binding whose initializer supplied declaration evidence.
  package let binding: PatternBindingSyntax

  /// Whether the reference is keyless or a keyed box.
  package let shape: CogDeclarationShape

  /// Whether the underlying declaration is automatic, writable, or asynchronous.
  package let origin: CogDeclarationOrigin

  /// Whether this name is a direct reference or a read-only projection.
  package let access: CogDeclarationAccess

  /// The classified base identifier this binding's `.readOnly` initializer projected.
  ///
  /// Present only for ``CogDeclarationAccess/readOnlyProjection`` evidence that
  /// came from a written `base.readOnly` initializer whose base the classifier
  /// had already recognized; annotation-only projection evidence carries `nil`
  /// because a written `Projection` type names no source. Naming rules use it
  /// to pair a projection with its underscored source declaration.
  package let projectedSourceName: String?

  /// The source identifier spelling without trivia.
  package var name: String { nameToken.text }

  /// Whether this exact declaration name is accepted as a writer target.
  package var isWritableSource: Bool {
    origin == .writableSource && access == .direct
  }

  /// Creates one classification from merged annotation and initializer evidence.
  package init(
    nameToken: TokenSyntax,
    declaration: VariableDeclSyntax,
    binding: PatternBindingSyntax,
    shape: CogDeclarationShape,
    origin: CogDeclarationOrigin,
    access: CogDeclarationAccess,
    projectedSourceName: String? = nil
  ) {
    self.nameToken = nameToken
    self.declaration = declaration
    self.binding = binding
    self.shape = shape
    self.origin = origin
    self.access = access
    self.projectedSourceName = projectedSourceName
  }
}
