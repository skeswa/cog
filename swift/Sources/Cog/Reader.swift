/// The read capability inside one run of a selector.
///
/// This is the `c` in `Cog { c in ... }`.
///
/// ```swift
/// let subtotal = Cog<Money> { c in
///   c[cart].items.reduce(.zero) { $0 + $1.price }
/// }
/// ```
///
/// `c[valueReference]` returns a value and records its dependency. Each run
/// replaces the dependency set, so branches and early returns work as expected.
/// Reads made outside this reader are invisible to Cog.
///
/// A reader is valid only during its selector run. Using a saved reader later
/// traps.
///
/// `c.peek` skips dependency tracking. `c.curr` returns this cog's previous
/// value without creating a self-dependency.
@MainActor
public struct Reader<Value> {
  /// The context whose graph this run reads.
  private let cogs: Cogtext

  /// The state receiving dependencies and providing `curr`.
  private let state: any CogReaderState<Value>

  /// Hands a run its reader. Only a state computing itself may make one.
  internal init(cogs: Cogtext, state: some CogReaderState<Value>) {
    self.cogs = cogs
    self.state = state
  }

  /// Reads a source, and depends on it.
  ///
  /// - Parameter valueReference: The source to read.
  /// - Returns: The value from the latest completed turn.
  public subscript<Read>(_ valueReference: ManualCog<Read>) -> Read {
    cogs.requireTracking(state)

    let producer = cogs.manualState(for: valueReference)
    state.recordDependency(on: producer)
    return producer.currentValue
  }

  /// Reads another derived cog, and depends on it.
  ///
  /// The first read computes the derived cog. Unread branches remain lazy.
  ///
  /// - Parameter valueReference: The derived cog to read.
  /// - Returns: Its value in this context.
  public subscript<Read>(_ valueReference: Cog<Read>) -> Read {
    cogs.requireTracking(state)

    let producer = cogs.derivedState(for: valueReference)
    state.recordDependency(on: producer)
    return producer.settledValue(in: cogs)
  }

  /// Reads an async cog's full phase and depends on it.
  public subscript<Read>(_ valueReference: AsyncCog<Read>) -> CogPhase<Read> {
    cogs.requireTracking(state)

    let producer = cogs.asyncState(for: valueReference)
    let phase = producer.settledPhase(in: cogs)
    state.recordDependency(on: producer)
    return phase
  }

  /// Reads a source exposed through `.readOnly`, and depends on it.
  ///
  /// This lets a selector read a published projection while the writable
  /// source stays `fileprivate` in its owning file.
  ///
  /// - Parameter valueReference: The read-only projection to read.
  /// - Returns: The value its source holds in the latest completed turn.
  public subscript<Read>(_ valueReference: CogProjection<Read>) -> Read {
    self[valueReference.source]
  }

  /// Peeks at a source without depending on it.
  ///
  /// Use this when the selector needs the source's current value but only a
  /// different tracked input should make the selector run again.
  ///
  /// - Parameter valueReference: The source to read without recording an edge.
  /// - Returns: The value the source holds in the latest completed turn.
  public func peek<Read>(_ valueReference: ManualCog<Read>) -> Read {
    cogs.requireTracking(state)
    return cogs.peek(valueReference)
  }

  /// Peeks at a derived cog without depending on it.
  ///
  /// Skipping the edge never returns stale data. If the derived cog is dirty,
  /// this call settles it before returning, but its later changes do not make
  /// this selector run again.
  ///
  /// - Parameter valueReference: The derived cog to read without recording an edge.
  /// - Returns: Its newest settled value in this context.
  public func peek<Read>(_ valueReference: Cog<Read>) -> Read {
    cogs.requireTracking(state)
    return cogs.peek(valueReference)
  }

  /// Peeks at an async cog without depending on it.
  public func peek<Read>(_ valueReference: AsyncCog<Read>) -> CogPhase<Read> {
    cogs.requireTracking(state)
    return cogs.peek(valueReference)
  }

  /// Peeks at a source exposed through `.readOnly` without depending on it.
  ///
  /// - Parameter valueReference: The read-only projection to read without recording an
  ///   edge.
  /// - Returns: The value its source holds in the latest completed turn.
  public func peek<Read>(_ valueReference: CogProjection<Read>) -> Read {
    peek(valueReference.source)
  }

  /// The value this cog retained after its previous completed run.
  ///
  /// The outer optional records whether a previous run exists. If `Value` is
  /// itself optional, `.none` means there has been no previous run while
  /// `.some(.none)` means the previous run produced `nil`.
  public var curr: Value? {
    cogs.requireTracking(state)
    return state.readerCurrentValue
  }

  /// The cycle a read of `valueReference` would close during this selector run.
  ///
  /// Package-only so the shipping Cog product exposes no diagnostic API.
  /// CogTesting wraps the rendered snapshot as its narrow public test seam.
  package func cycleDiagnosticSnapshot<Read>(
    ifReading valueReference: Cog<Read>
  ) -> CogCycleDiagnosticSnapshot? {
    cogs.requireTracking(state)
    return cogs.cycleDiagnosticSnapshot(ifReading: valueReference)
  }
}
