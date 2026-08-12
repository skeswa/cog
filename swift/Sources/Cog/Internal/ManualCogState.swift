/// The live state behind one ``ManualCog`` value reference, in one context.
///
/// A manual state holds a value written by turns. It is always settled, so reads
/// return its current value without graph work.
///
/// A context creates it on first use from
/// ``ManualCogDescriptor/startingValue(forKey:)``.
internal final class ManualCogState<Value>: CogState, PendingCogSource, CogObservationState {
  /// The declaration this state belongs to.
  ///
  /// Provides the label, equality rule, and lifetime.
  let descriptor: ManualCogDescriptor<Value>

  /// Which state of `descriptor` this is, or `nil` for a keyless declaration.
  ///
  /// Used to print names such as `weather[90210]` (§2.4).
  let key: AnyHashable?

  /// What this source holds in the latest completed turn or changed debug seed.
  ///
  /// Normal reads use this slot while a turn accumulates, so staged values stay
  /// behind the commit boundary (§2.2).
  var currentValue: Value

  /// What the accumulating turn has staged, if anything.
  ///
  /// This optional is storage presence, not value optionality. When `Value`
  /// itself is optional, `.some(.none)` means the turn staged nil,
  /// while `.none` means it did not write this source.
  var pendingValue: Value?

  /// Sources are always settled: their current slot is already their value.
  var settleState: CogSettleState

  /// The revision of the last committed change.
  var changedAt: CogVersion

  /// The revision through which the current slot was last verified.
  var checkedAt: CogVersion

  /// Derived states whose last run read this source.
  var subscribers: [CogSubscriberEdge]

  /// Created only after this exact descriptor-and-key state reaches the UI.
  var observationBoundary: CogObservationBoundary?

  var observationKey: AnyHashable? { key }

  var label: CogLabel { descriptor.label }

  /// Moves a staged value across the commit boundary, if this turn wrote one.
  func flushPendingValue(in cogs: Cogtext, at revision: CogVersion) {
    guard case .some(let value) = pendingValue else { return }
    pendingValue = .none

    // Compare only the final staged value. A write followed by a reversion does
    // not invalidate downstream states.
    guard !descriptor.valuesAreEqual(currentValue, value) else { return }

    currentValue = value

    // Record only writes that changed state. Reverted writes are invisible to
    // the graph and should not evict useful history entries.
    #if DEBUG
    cogs.historyLog.recordWrite(label: label, key: key)
    #endif

    markChanged(at: revision)
    cogs.invalidateSubscribers(of: self)
  }

  /// Creates the state at its declaration's starting value for this key.
  ///
  /// A per-key starting closure runs here once. Later writes replace its value.
  init(descriptor: ManualCogDescriptor<Value>, key: AnyHashable?) {
    self.descriptor = descriptor
    self.key = key
    self.currentValue = descriptor.startingValue(forKey: key)
    self.pendingValue = nil
    self.settleState = .clean
    self.changedAt = .initial
    self.checkedAt = .initial
    self.subscribers = []
    self.observationBoundary = nil
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
