/// The live state behind one ``ManualCog`` value reference, in one context.
///
/// A manual source is the simplest state there is: it holds a value, and that
/// value changes only when a turn writes it. Nothing computes it, so it is
/// always settled — a read of a source can hand back what it holds without
/// doing any graph work first. A derived state may need settlement before a
/// read can return.
///
/// The state is created the first time a context is asked for this descriptor
/// and key, and it starts at the declaration's starting value because there is
/// no earlier turn to ask (see ``ManualCogDescriptor/startingValue``).
internal final class ManualCogState<Value>: CogState, PendingCogSource {
  /// The declaration this state belongs to.
  ///
  /// Holding the descriptor gives the state its label, equality rule, and
  /// lifetime without copying them.
  let descriptor: ManualCogDescriptor<Value>

  /// Which state of `descriptor` this is, or `nil` for a keyless declaration.
  ///
  /// The state knows its own key so a diagnostic can name it — `weather[90210]`
  /// rather than `weather` — without a reverse lookup through the context's
  /// storage (§2.4).
  let key: AnyHashable?

  /// What this source holds in the latest completed turn or changed debug seed.
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

  /// Derived states whose last run read this source.
  var subscribers: [CogSubscriberEdge]

  var label: CogLabel { descriptor.label }

  /// Moves a staged value across the commit boundary, if this turn wrote one.
  func flushPendingValue(in cogs: Cogtext, at revision: CogVersion) {
    guard case .some(let value) = pendingValue else { return }
    pendingValue = .none

    // Equality is decided against the final staged value, once, at flush.
    // That makes repeated writes cheap and makes a change followed by a
    // reversion disappear without ever dirtying downstream states.
    guard !descriptor.valuesAreEqual(currentValue, value) else { return }

    currentValue = value

    // Recorded below the equality gate, so history holds writes that changed
    // something. A write reverted within its own turn is invisible to every
    // other part of the model, and a history that contradicted the model would
    // mislead the person reading it — besides letting one unchanged write in a
    // loop evict the whole ring.
    #if DEBUG
    cogs.historyLog.recordWrite(label: label, key: key)
    #endif

    markChanged(at: revision)
    cogs.invalidateSubscribers(of: self)
  }

  /// Creates the state at its declaration's starting value for this key.
  ///
  /// The key is part of the question, not just part of the filing: a keyed
  /// declaration may start each key at its own value (`ManualCogBox<Int,
  /// ZipCode> { zip in ... }`), and that closure runs here — once, when this
  /// state first appears — rather than on every read. Whatever it returns is a
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
