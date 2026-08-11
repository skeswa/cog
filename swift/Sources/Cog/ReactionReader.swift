/// The read capability inside one run of a reaction.
///
/// This is the `c` in `cogs.run { c in ... }`. Reading through ``get(_:)``
/// both returns the latest settled value and records it as a dependency of the
/// reaction run in progress. A later turn reruns the reaction only when one of
/// those dependencies changes.
///
/// A reaction reader deliberately exposes no write operation. A reaction that
/// needs to change graph state calls an op on its context, which opens a new
/// turn after the active flush rather than mutating the turn being observed.
/// Like ``Reader``, this value is valid only for the run that handed it out.
@MainActor
public struct ReactionReader {
  private let cogs: Cogtext
  private let reaction: CogReaction

  internal init(cogs: Cogtext, reaction: CogReaction) {
    self.cogs = cogs
    self.reaction = reaction
  }

  /// Reads a source and records it as a dependency of this reaction run.
  public func get<Value>(_ ref: ManualCog<Value>) -> Value {
    cogs.requireTracking(reaction)

    let producer = cogs.manualNode(for: ref)
    reaction.recordDependency(on: producer)
    return producer.currentValue
  }

  /// Reads a derived cog and records it as a dependency of this reaction run.
  public func get<Value>(_ ref: Cog<Value>) -> Value {
    cogs.requireTracking(reaction)

    let producer = cogs.derivedNode(for: ref)
    reaction.recordDependency(on: producer)
    return producer.settledValue(in: cogs)
  }

  /// Reads a source's read-only projection and records the source dependency.
  public func get<Value>(_ ref: ReadOnlyCog<Value>) -> Value {
    get(ref.source)
  }
}
