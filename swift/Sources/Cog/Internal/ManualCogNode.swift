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
internal final class ManualCogNode<Value>: CogNode, PendingCogSource {
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

  /// What this source holds in the latest completed turn.
  ///
  /// Normal reads use only this slot, including while another turn is still
  /// accumulating. That is what prevents a staged value from leaking across
  /// the structural commit boundary (§2.2).
  var currentValue: Value

  /// What the accumulating turn has staged, if anything.
  ///
  /// This optional is storage presence, not value optionality. When `Value`
  /// itself is optional, `.some(.none)` means the turn really did stage nil,
  /// while `.none` means it did not write this source.
  var pendingValue: Value?

  /// Sources are always settled: their current slot is already their value.
  var settleState: CogSettleState

  /// The revision of the last committed real change.
  var changedAt: CogVersion

  /// The revision through which the current slot was last verified.
  var checkedAt: CogVersion

  /// Derived nodes whose last run read this source.
  var subscribers: [CogSubscriberEdge]

  var label: CogLabel { descriptor.label }

  /// Moves a staged value across the commit boundary, if this turn wrote one.
  func flushPendingValue(in cogs: Cogtext, at revision: CogVersion) {
    guard case .some(let value) = pendingValue else { return }
    currentValue = value
    pendingValue = .none
    markChanged(at: revision)
    cogs.invalidateSubscribers(of: self)
  }

  /// Creates the node at its declaration's starting value for this key.
  ///
  /// The key is part of the question, not just part of the filing: a keyed
  /// declaration may start each key at its own value (`ManualCogBox<Int,
  /// ZipCode> { zip in ... }`), and that closure runs here — once, when this
  /// node first appears — rather than on every read. Whatever it returns is a
  /// starting value like any other, so a later write replaces it and the
  /// closure is never consulted again for this key in this context.
  init(descriptor: ManualCogDescriptor<Value>, key: AnyHashable?) {
    self.descriptor = descriptor
    self.key = key
    self.currentValue = descriptor.startingValue(forKey: key)
    self.pendingValue = nil
    self.settleState = .clean
    self.changedAt = .initial
    self.checkedAt = .initial
    self.subscribers = []
  }

  // Written out, and `nonisolated`, per the rule at the top of
  // `CogDescriptor.swift`. Removing it crashes the release build.
  nonisolated deinit {}
}

/// The type-erased flush capability one turn needs from a touched source.
@MainActor
internal protocol PendingCogSource: AnyObject {
  func flushPendingValue(in cogs: Cogtext, at revision: CogVersion)
}
