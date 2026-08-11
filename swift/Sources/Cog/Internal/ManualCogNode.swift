/// The live state behind one ``ManualCog`` ref, in one context.
///
/// A manual source is the simplest node there is: it holds a value, and that
/// value changes only when a turn writes it. Nothing computes it, so it is
/// always settled — a read of a source can hand back what it holds without
/// doing any graph work first. Derived nodes, which are not always settled,
/// arrive with `M1-05a`.
///
/// The node is created the first time a context is asked for this descriptor
/// and key, and it starts at the declaration's starting value because there is
/// no earlier turn to ask (see ``ManualCogDescriptor/startingValue``).
internal final class ManualCogNode<Value>: CogNode {
  /// The declaration this node belongs to.
  ///
  /// Holding the descriptor rather than copying pieces out of it keeps the
  /// node able to answer questions the declaration owns — its label now, its
  /// equality rule and lifetime kind later — and costs nothing, since a
  /// descriptor is normally owned by a top-level `let` that outlives every
  /// context anyway.
  let descriptor: ManualCogDescriptor<Value>

  /// Which node of `descriptor` this is, or `nil` for a keyless declaration.
  ///
  /// The node knows its own key so a diagnostic can name it — `weather[90210]`
  /// rather than `weather` — without a reverse lookup through the context's
  /// storage (§2.4).
  let key: AnyHashable?

  /// What this source currently holds.
  ///
  /// One value today, because there are no turns yet. `M1-04aa` splits the
  /// committed value from the value a commit has staged but not yet flushed;
  /// normal reads keep returning this one, which is the committed side.
  var value: Value

  var label: CogLabel { descriptor.label }

  /// Creates the node at its declaration's starting value.
  init(descriptor: ManualCogDescriptor<Value>, key: AnyHashable?) {
    self.descriptor = descriptor
    self.key = key
    self.value = descriptor.startingValue
  }

  // Written out, and `nonisolated`, per the rule at the top of
  // `CogDescriptor.swift`. Removing it crashes the release build.
  nonisolated deinit {}
}
