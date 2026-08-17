#if COG_VALUE_REFERENCE_LAYOUT_GENERIC

// Mechanism registration is a public consumer of value references, so the
// generic candidate needs keyed overloads here as well as on ordinary readers.
// Delegation preserves the existing scope, ordering, attribution, and lifetime
// machinery after the concrete key has crossed the capability boundary.

extension MechanismController {
  /// Watches a generic candidate's keyed manual source.
  public func watch<Value, Key: Hashable>(
    _ valueReference: ManualCogBox<Value, Key>.ValueReference,
    initial: CogWatchStart,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ body: @escaping @MainActor (Value, Value) -> Void
  ) {
    watch(
      valueReference.simpleCoreReference,
      initial: initial,
      name: name,
      fileID: fileID,
      line: line,
      body
    )
  }

  /// Watches a generic candidate's keyed derived value.
  public func watch<Value, Key: Hashable>(
    _ valueReference: CogBox<Value, Key>.ValueReference,
    initial: CogWatchStart,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ body: @escaping @MainActor (Value, Value) -> Void
  ) {
    watch(
      valueReference.simpleCoreReference,
      initial: initial,
      name: name,
      fileID: fileID,
      line: line,
      body
    )
  }

  /// Watches a generic candidate's total keyed async value.
  public func watch<Value, Key: Hashable>(
    _ valueReference: AsyncCogBox<Value, Key>.ValueReference,
    initial: CogWatchStart,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ body: @escaping @MainActor (Value, Value) -> Void
  ) {
    watch(
      valueReference.simpleCoreReference,
      initial: initial,
      name: name,
      fileID: fileID,
      line: line,
      body
    )
  }

  /// Watches a generic candidate's read-only keyed manual source.
  public func watch<Value, Key: Hashable>(
    _ valueReference: CogBoxProjection<Value, Key>.ValueReference,
    initial: CogWatchStart,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ body: @escaping @MainActor (Value, Value) -> Void
  ) {
    watch(
      valueReference.simpleCoreReference,
      initial: initial,
      name: name,
      fileID: fileID,
      line: line,
      body
    )
  }

  /// Opens a nested scope while a generic keyed derived Bool reads true.
  public func whenever<Key: Hashable>(
    _ gate: CogBox<Bool, Key>.ValueReference,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ body: @escaping @MainActor (MechanismController) -> Void
  ) {
    whenever(
      gate.simpleCoreReference,
      name: name,
      fileID: fileID,
      line: line,
      body
    )
  }

  /// Opens a nested scope while a generic keyed manual Bool reads true.
  public func whenever<Key: Hashable>(
    _ gate: ManualCogBox<Bool, Key>.ValueReference,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ body: @escaping @MainActor (MechanismController) -> Void
  ) {
    whenever(
      gate.simpleCoreReference,
      name: name,
      fileID: fileID,
      line: line,
      body
    )
  }

  /// Opens a nested scope while a generic read-only keyed Bool reads true.
  public func whenever<Key: Hashable>(
    _ gate: CogBoxProjection<Bool, Key>.ValueReference,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ body: @escaping @MainActor (MechanismController) -> Void
  ) {
    whenever(
      gate.simpleCoreReference,
      name: name,
      fileID: fileID,
      line: line,
      body
    )
  }
}

extension MechanismController.Status {
  /// Watches a generic candidate's keyed async status.
  public func watch<Value, Key: Hashable>(
    _ valueReference: AsyncCogBox<Value, Key>.ValueReference,
    initial: CogWatchStart,
    name: String? = nil,
    fileID: StaticString = #fileID,
    line: UInt = #line,
    _ body: @escaping @MainActor (CogStatus<Value>, CogStatus<Value>) -> Void
  ) {
    controller.status.watch(
      valueReference.simpleCoreReference,
      initial: initial,
      name: name,
      fileID: fileID,
      line: line,
      body
    )
  }

  /// Peeks at a generic candidate's keyed async status without registration.
  public func peek<Value, Key: Hashable>(
    _ valueReference: AsyncCogBox<Value, Key>.ValueReference
  ) -> CogStatus<Value> {
    controller.status.peek(valueReference.simpleCoreReference)
  }
}

#endif
