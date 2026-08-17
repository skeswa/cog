#if COG_VALUE_REFERENCE_LAYOUT_GENERIC

// The generic value-reference candidate keeps `Key` specialized from
// `box[key]` until a runtime capability receives the reference. These
// overloads preserve the ordinary inferred API spellings while adapting to
// M5's heterogeneous class-state core at the shell. The benchmark therefore
// measures both the narrower construction representation and the erasure cost
// this core still pays; M6's descriptor-local concrete-key lookup can remove
// the latter without changing these public reference types.

// MARK: - UI-boundary and one-shot reads

extension Cogs {
  /// Reads and observes a generic candidate's keyed manual source.
  public subscript<Value, Key: Hashable>(
    _ valueReference: ManualCogBox<Value, Key>.ValueReference
  ) -> Value {
    self[valueReference.simpleCoreReference]
  }

  /// Reads and observes a generic candidate's keyed derived value.
  public subscript<Value, Key: Hashable>(
    _ valueReference: CogBox<Value, Key>.ValueReference
  ) -> Value {
    self[valueReference.simpleCoreReference]
  }

  /// Reads and observes a generic candidate's total keyed async value.
  public subscript<Value, Key: Hashable>(
    _ valueReference: AsyncCogBox<Value, Key>.ValueReference
  ) -> Value {
    self[valueReference.simpleCoreReference]
  }

  /// Reads and observes a generic candidate's read-only keyed source.
  public subscript<Value, Key: Hashable>(
    _ valueReference: CogBoxProjection<Value, Key>.ValueReference
  ) -> Value {
    self[valueReference.simpleCoreReference]
  }
}

extension Cogs.Status {
  /// Reads and observes a generic candidate's keyed async status.
  public subscript<Value, Key: Hashable>(
    _ valueReference: AsyncCogBox<Value, Key>.ValueReference
  ) -> CogStatus<Value> {
    self[valueReference.simpleCoreReference]
  }

  /// Reads a generic candidate's keyed async status without observation.
  public func peek<Value, Key: Hashable>(
    _ valueReference: AsyncCogBox<Value, Key>.ValueReference
  ) -> CogStatus<Value> {
    peek(valueReference.simpleCoreReference)
  }
}

// MARK: - Selector reads

extension Reader {
  /// Reads and depends on a generic candidate's keyed manual source.
  public subscript<Read, Key: Hashable>(
    _ valueReference: ManualCogBox<Read, Key>.ValueReference
  ) -> Read {
    self[valueReference.simpleCoreReference]
  }

  /// Reads and depends on a generic candidate's keyed derived value.
  public subscript<Read, Key: Hashable>(
    _ valueReference: CogBox<Read, Key>.ValueReference
  ) -> Read {
    self[valueReference.simpleCoreReference]
  }

  /// Reads and depends on a generic candidate's total keyed async value.
  public subscript<Read, Key: Hashable>(
    _ valueReference: AsyncCogBox<Read, Key>.ValueReference
  ) -> Read {
    self[valueReference.simpleCoreReference]
  }

  /// Reads and depends on a generic candidate's read-only keyed source.
  public subscript<Read, Key: Hashable>(
    _ valueReference: CogBoxProjection<Read, Key>.ValueReference
  ) -> Read {
    self[valueReference.simpleCoreReference]
  }

  /// Peeks at a generic candidate's keyed manual source without an edge.
  public func peek<Read, Key: Hashable>(
    _ valueReference: ManualCogBox<Read, Key>.ValueReference
  ) -> Read {
    peek(valueReference.simpleCoreReference)
  }

  /// Peeks at a generic candidate's keyed derived value without an edge.
  public func peek<Read, Key: Hashable>(
    _ valueReference: CogBox<Read, Key>.ValueReference
  ) -> Read {
    peek(valueReference.simpleCoreReference)
  }

  /// Peeks at a generic candidate's total keyed async value without an edge.
  public func peek<Read, Key: Hashable>(
    _ valueReference: AsyncCogBox<Read, Key>.ValueReference
  ) -> Read {
    peek(valueReference.simpleCoreReference)
  }

  /// Peeks at a generic candidate's read-only keyed source without an edge.
  public func peek<Read, Key: Hashable>(
    _ valueReference: CogBoxProjection<Read, Key>.ValueReference
  ) -> Read {
    peek(valueReference.simpleCoreReference)
  }
}

extension Reader.Status {
  /// Reads and depends on a generic candidate's keyed async status.
  public subscript<Read, Key: Hashable>(
    _ valueReference: AsyncCogBox<Read, Key>.ValueReference
  ) -> CogStatus<Read> {
    self[valueReference.simpleCoreReference]
  }

  /// Peeks at a generic candidate's keyed async status without an edge.
  public func peek<Read, Key: Hashable>(
    _ valueReference: AsyncCogBox<Read, Key>.ValueReference
  ) -> CogStatus<Read> {
    peek(valueReference.simpleCoreReference)
  }
}

// MARK: - Reaction reads

extension ReactionReader {
  /// Reads and depends on a generic candidate's keyed manual source.
  public subscript<Value, Key: Hashable>(
    _ valueReference: ManualCogBox<Value, Key>.ValueReference
  ) -> Value {
    self[valueReference.simpleCoreReference]
  }

  /// Reads and depends on a generic candidate's keyed derived value.
  public subscript<Value, Key: Hashable>(
    _ valueReference: CogBox<Value, Key>.ValueReference
  ) -> Value {
    self[valueReference.simpleCoreReference]
  }

  /// Reads and depends on a generic candidate's total keyed async value.
  public subscript<Value, Key: Hashable>(
    _ valueReference: AsyncCogBox<Value, Key>.ValueReference
  ) -> Value {
    self[valueReference.simpleCoreReference]
  }

  /// Reads and depends on a generic candidate's read-only keyed source.
  public subscript<Value, Key: Hashable>(
    _ valueReference: CogBoxProjection<Value, Key>.ValueReference
  ) -> Value {
    self[valueReference.simpleCoreReference]
  }

  /// Peeks at a generic candidate's keyed manual source without an edge.
  public func peek<Value, Key: Hashable>(
    _ valueReference: ManualCogBox<Value, Key>.ValueReference
  ) -> Value {
    peek(valueReference.simpleCoreReference)
  }

  /// Peeks at a generic candidate's keyed derived value without an edge.
  public func peek<Value, Key: Hashable>(
    _ valueReference: CogBox<Value, Key>.ValueReference
  ) -> Value {
    peek(valueReference.simpleCoreReference)
  }

  /// Peeks at a generic candidate's total keyed async value without an edge.
  public func peek<Value, Key: Hashable>(
    _ valueReference: AsyncCogBox<Value, Key>.ValueReference
  ) -> Value {
    peek(valueReference.simpleCoreReference)
  }

  /// Peeks at a generic candidate's read-only keyed source without an edge.
  public func peek<Value, Key: Hashable>(
    _ valueReference: CogBoxProjection<Value, Key>.ValueReference
  ) -> Value {
    peek(valueReference.simpleCoreReference)
  }
}

extension ReactionReader.Status {
  /// Reads and depends on a generic candidate's keyed async status.
  public subscript<Value, Key: Hashable>(
    _ valueReference: AsyncCogBox<Value, Key>.ValueReference
  ) -> CogStatus<Value> {
    self[valueReference.simpleCoreReference]
  }

  /// Peeks at a generic candidate's keyed async status without an edge.
  public func peek<Value, Key: Hashable>(
    _ valueReference: AsyncCogBox<Value, Key>.ValueReference
  ) -> CogStatus<Value> {
    peek(valueReference.simpleCoreReference)
  }
}

// MARK: - Writes and shared ops

extension Writer {
  /// Reads or stages a generic candidate's keyed manual source in this turn.
  public subscript<Value, Key: Hashable>(
    _ valueReference: ManualCogBox<Value, Key>.ValueReference
  ) -> Value {
    get { self[valueReference.simpleCoreReference] }
    nonmutating set { self[valueReference.simpleCoreReference] = newValue }
  }
}

extension CogOps {
  /// Peeks at a generic candidate's keyed manual source.
  public func peek<Value, Key: Hashable>(
    _ valueReference: ManualCogBox<Value, Key>.ValueReference
  ) -> Value {
    peek(valueReference.simpleCoreReference)
  }

  /// Peeks at a generic candidate's keyed derived value.
  public func peek<Value, Key: Hashable>(
    _ valueReference: CogBox<Value, Key>.ValueReference
  ) -> Value {
    peek(valueReference.simpleCoreReference)
  }

  /// Peeks at a generic candidate's total keyed async value.
  public func peek<Value, Key: Hashable>(
    _ valueReference: AsyncCogBox<Value, Key>.ValueReference
  ) -> Value {
    peek(valueReference.simpleCoreReference)
  }

  /// Peeks at a generic candidate's read-only keyed source.
  public func peek<Value, Key: Hashable>(
    _ valueReference: CogBoxProjection<Value, Key>.ValueReference
  ) -> Value {
    peek(valueReference.simpleCoreReference)
  }

  /// Commits one value to a generic candidate's keyed manual source.
  public func commit<Value, Key: Hashable>(
    _ valueReference: ManualCogBox<Value, Key>.ValueReference,
    to value: Value,
    name: String = #function
  ) {
    commit(named: name) { writer in
      writer[valueReference] = value
    }
  }

  /// Demands one fresh generation of a generic candidate's keyed async value.
  @discardableResult
  public func refresh<Value, Key: Hashable>(
    _ valueReference: AsyncCogBox<Value, Key>.ValueReference
  ) -> CogRefresh<Value> {
    refresh(valueReference.simpleCoreReference)
  }
}

// MARK: - CogTesting package seams

extension Cogs {
  /// Resolves a generic candidate's keyed manual reference for infrastructure tests.
  internal func manualState<Value, Key: Hashable>(
    for valueReference: ManualCogBox<Value, Key>.ValueReference
  ) -> ManualCogState<Value> {
    manualState(for: valueReference.simpleCoreReference)
  }

  /// Resolves a generic candidate's keyed derived reference for infrastructure tests.
  internal func derivedState<Value, Key: Hashable>(
    for valueReference: CogBox<Value, Key>.ValueReference
  ) -> DerivedCogState<Value> {
    derivedState(for: valueReference.simpleCoreReference)
  }

  /// Resolves a generic candidate's keyed async reference for infrastructure tests.
  #if COG_CORE_SIMPLE
  internal func asyncState<Value, Key: Hashable>(
    for valueReference: AsyncCogBox<Value, Key>.ValueReference
  ) -> AsyncCogState<Value> {
    asyncState(for: valueReference.simpleCoreReference)
  }
  #endif
}

extension Reader {
  /// Diagnoses a keyed derived read without exposing generic-core storage to CogTesting.
  package func cycleDiagnosticSnapshot<Read, Key: Hashable>(
    ifReading valueReference: CogBox<Read, Key>.ValueReference
  ) -> CogCycleDiagnosticSnapshot? {
    cycleDiagnosticSnapshot(ifReading: valueReference.simpleCoreReference)
  }
}

extension Cogs {
  /// Reports whether a generic keyed manual source owns an Observation boundary.
  package func hasObservationBoundaryForTesting<Value, Key: Hashable>(
    for valueReference: ManualCogBox<Value, Key>.ValueReference
  ) -> Bool {
    hasObservationBoundaryForTesting(for: valueReference.simpleCoreReference)
  }

  /// Reports whether a generic keyed derived value owns an Observation boundary.
  package func hasObservationBoundaryForTesting<Value, Key: Hashable>(
    for valueReference: CogBox<Value, Key>.ValueReference
  ) -> Bool {
    hasObservationBoundaryForTesting(for: valueReference.simpleCoreReference)
  }

  #if DEBUG
  /// Seeds a generic candidate's keyed manual source during idle test setup.
  package func seedForTesting<Value, Key: Hashable>(
    _ valueReference: ManualCogBox<Value, Key>.ValueReference,
    to value: Value
  ) {
    seedForTesting(valueReference.simpleCoreReference, to: value)
  }
  #endif
}

#endif
