/// The read capability inside one run of a reaction.
///
/// This is the `c` in `cogs.run { c in ... }`. Reading through the subscript
/// both returns the latest settled value and records it as a dependency of the
/// reaction run in progress. A later turn reruns the reaction only when one of
/// those dependencies changes.
///
/// `c.peek(valueReference)` returns a current settled value without recording
/// it as a dependency.
///
/// To write, call an op on the context. Its commit runs as a new turn after the
/// active flush. Like ``Reader``, this value is valid only during its run.
@MainActor
public struct ReactionReader {
  private let cogs: Cogtext
  private let reaction: CogReaction

  internal init(cogs: Cogtext, reaction: CogReaction) {
    self.cogs = cogs
    self.reaction = reaction
  }

  /// Reads a source and records it as a dependency of this reaction run.
  public subscript<Value>(_ valueReference: ManualCog<Value>) -> Value {
    cogs.requireTracking(reaction)

    let producer = cogs.manualState(for: valueReference)
    reaction.recordDependency(on: producer)
    return producer.currentValue
  }

  /// Reads a derived cog and records it as a dependency of this reaction run.
  public subscript<Value>(_ valueReference: Cog<Value>) -> Value {
    cogs.requireTracking(reaction)

    let producer = cogs.derivedState(for: valueReference)
    reaction.recordDependency(on: producer)
    return producer.settledValue(in: cogs)
  }

  /// Reads an async cog's full phase and records it as a dependency.
  public subscript<Value>(_ valueReference: AsyncCog<Value>) -> CogPhase<Value> {
    cogs.requireTracking(reaction)

    let producer = cogs.asyncState(for: valueReference)
    let phase = producer.settledPhase(in: cogs)
    reaction.recordDependency(on: producer)
    return phase
  }

  /// Reads a source's read-only projection and records the source dependency.
  public subscript<Value>(_ valueReference: CogProjection<Value>) -> Value {
    self[valueReference.source]
  }

  /// Peeks at a source without recording it as a reaction dependency.
  public func peek<Value>(_ valueReference: ManualCog<Value>) -> Value {
    cogs.requireTracking(reaction)
    return cogs.peek(valueReference)
  }

  /// Peeks at a derived cog without recording it as a reaction dependency.
  ///
  /// A dirty value is settled before it is returned.
  public func peek<Value>(_ valueReference: Cog<Value>) -> Value {
    cogs.requireTracking(reaction)
    return cogs.peek(valueReference)
  }

  /// Peeks at an async cog without recording a dependency.
  public func peek<Value>(_ valueReference: AsyncCog<Value>) -> CogPhase<Value> {
    cogs.requireTracking(reaction)
    return cogs.peek(valueReference)
  }

  /// Peeks at a source's read-only projection without recording a dependency.
  public func peek<Value>(_ valueReference: CogProjection<Value>) -> Value {
    peek(valueReference.source)
  }
}
