/// The read capability inside one run of a reaction.
///
/// This is the `c` in `cogs.run { c in ... }`. Reading through ``get(_:)``
/// both returns the latest settled value and records it as a dependency of the
/// reaction run in progress. A later turn reruns the reaction only when one of
/// those dependencies changes.
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
  public func get<Value>(_ valueReference: ManualCog<Value>) -> Value {
    cogs.requireTracking(reaction)

    let producer = cogs.manualState(for: valueReference)
    reaction.recordDependency(on: producer)
    return producer.currentValue
  }

  /// Reads a derived cog and records it as a dependency of this reaction run.
  public func get<Value>(_ valueReference: Cog<Value>) -> Value {
    cogs.requireTracking(reaction)

    let producer = cogs.derivedState(for: valueReference)
    reaction.recordDependency(on: producer)
    return producer.settledValue(in: cogs)
  }

  /// Reads a source's read-only projection and records the source dependency.
  public func get<Value>(_ valueReference: CogProjection<Value>) -> Value {
    get(valueReference.source)
  }
}
