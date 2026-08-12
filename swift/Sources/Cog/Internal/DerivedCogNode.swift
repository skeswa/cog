/// The live state behind one ``Cog`` ref, in one context.
///
/// A derived node is the other half of ``ManualCogNode``: nothing writes it,
/// and everything about it comes from running its declaration's selector. That
/// run is what makes it lazy and what makes it cacheable — the two behaviors
/// this node exists to provide (§2.2).
///
/// **Lazy.** The node computes nothing when it is created. A declaration is a
/// name, and an app that declares a hundred derived values and reads three
/// should run three selectors. The first read is what runs the selector, and
/// a node that is never read never runs at all (`DECL-09`).
///
/// **Cached.** A run's value is kept, so a second read is a lookup rather than
/// a second run (`READ-02`). CLEAN/CHECK/DIRTY state and versions make that
/// cache valid across source writes: a read pulls every dirty dependency it
/// needs current before returning. Equality backdating stops downstream work
/// when a rerun lands equal; dynamic edge removal remains the separately
/// tested recapture slice.
///
/// The dependencies a run captured are recorded even though nothing consumes
/// them yet, because they are captured *by the run* (§2.4) and there is no
/// second chance to collect them later. `M1-06aa` reads them to walk parents,
/// and `M1-09a` makes recapture across conditionals and early returns
/// observable.
internal final class DerivedCogNode<Value>:
  CogNode, CogConsumer, DerivedCogSettleNode, CogLifetimeLeaseNode
{
  /// The declaration this node belongs to.
  let descriptor: DerivedCogDescriptor<Value>

  /// Which node of `descriptor` this is, or `nil` for a keyless declaration.
  ///
  /// A box node knows its own key so a diagnostic can name it — for example,
  /// `isNiceOutside[90210]` rather than `isNiceOutside` — without a reverse
  /// lookup through the context's storage (§2.4).
  let key: AnyHashable?

  /// What the last run of the selector produced, or `.none` if it has never
  /// run in this context.
  ///
  /// This optional is storage presence, not value optionality, the same
  /// distinction ``ManualCogNode/pendingValue`` makes. When `Value` is itself
  /// optional, `.some(.none)` means a run really did produce nil — which must
  /// hit the cache, not run the selector a second time.
  internal private(set) var cachedValue: Value?

  /// The producers the last run read through `c.get`, in read order.
  ///
  /// Rebuilt from empty on every run, because dependencies are exactly what
  /// this run read (§2.4) and an edge that is not read again is not an edge.
  /// A list, with repeats left in, is the correctness build's answer. Reverse
  /// edges are reused for producers that remain and removed from producers the
  /// next run drops. The physical layout remains benchmark-gated for `M6`
  /// (perf §3.3).
  internal private(set) var dependencies: [any CogNode] = []

  /// Fresh derived nodes are DIRTY because they have no value to return yet.
  var settleState: CogSettleState

  /// The revision in which the cached value last really changed.
  var changedAt: CogVersion

  /// The revision through which the cached value was last proved current.
  var checkedAt: CogVersion

  /// Consumers whose last run read this derived value.
  var subscribers: [CogSubscriberEdge]

  var label: CogLabel { descriptor.label }

  /// The declaration's lifetime policy, shared by every key of a box.
  var lifetime: CogNodeLifetime { descriptor.lifetime }

  /// External consumers currently keeping this derived root observed.
  var externalLeaseCount: Int

  /// Whether the selector has run in this context yet.
  ///
  /// Named separately from the cache so that a caller asking the lazy question
  /// does not have to know how the answer is stored.
  var hasComputed: Bool {
    if case .some = cachedValue {
      return true
    }
    return false
  }

  /// Creates the node without computing anything.
  init(descriptor: DerivedCogDescriptor<Value>, key: AnyHashable?) {
    self.descriptor = descriptor
    self.key = key
    self.cachedValue = .none
    self.settleState = .dirty
    self.changedAt = .initial
    self.checkedAt = .initial
    self.subscribers = []
    self.externalLeaseCount = 0
  }

  /// The node's value, running the selector if this is its first read.
  ///
  /// Every read of a derived cog goes through here — tracked or untracked,
  /// from a selector or from outside one — so that no caller can spell a read
  /// that skips the computation. `M1-06aa` adds the settle check to the same
  /// choke point, which is why it is stated as "settled value" rather than
  /// "cached value or run".
  func settledValue(in cogs: Cogtext) -> Value {
    guard hasComputed else {
      return run(in: cogs)
    }

    if settleState != .clean {
      cogs.settle(self)
    }

    guard case .some(let cached) = cachedValue else {
      fatalError("A settled derived Cog lost its cached value.")
    }
    return cached
  }

  func recordDependency(on producer: any CogNode) {
    dependencies.append(producer)
    producer.addSubscriber(self)
  }

  func releaseDependenciesForContextTeardown() {
    dependencies.removeAll()
  }

  /// Reruns the generic selector behind a type-erased settle exit frame.
  func recompute(in cogs: Cogtext) {
    _ = run(in: cogs)
  }

  /// Runs the selector once, tracking what it reads, and keeps the result.
  ///
  /// The node installs itself as the context's tracked consumer for the
  /// duration of the run, so a nested read of another derived cog computes
  /// that cog against *itself* and hands tracking back on the way out.
  private func run(in cogs: Cogtext) -> Value {
    #if DEBUG
    // Reader tracking ends before the user-supplied equality check below. Keep
    // debug seed blocked until the node has recorded the result, or a seed from
    // that equality closure could be cleaned over and leave this cache stale.
    cogs.seedBarrierDepth += 1
    defer { cogs.seedBarrierDepth -= 1 }
    #endif

    // Recorded here rather than in `recompute(in:)`, because this is the one
    // place the selector actually runs: recording at the settle-driven entry
    // would miss every lazy first computation, which is a large part of what a
    // person wants history to explain. Recorded on the way in rather than at
    // either exit, so a rerun that lands on an equal value still shows the run
    // it really did.
    #if DEBUG
    cogs.historyLog.recordRecompute(label: label, key: key)
    #endif

    let previousValue = cachedValue
    let previousDependencies = dependencies
    dependencies.removeAll(keepingCapacity: true)

    let value = cogs.tracking(self) {
      descriptor.compute(Reader(cogs: cogs, node: self), key: key)
    }

    for previousDependency in previousDependencies
    where !dependencies.contains(where: { $0 === previousDependency }) {
      previousDependency.removeSubscriber(self)
    }

    if case .some(let previousValue) = previousValue,
      descriptor.valuesAreEqual(previousValue, value)
    {
      // Equality backdates the recomputation: dependencies were recaptured and
      // the node is current through this revision, but its value did not
      // change in it. Keeping `changedAt` old is what lets a CHECK consumer
      // stop without running.
      markChecked(at: cogs.revision)
      return previousValue
    }

    cachedValue = .some(value)
    markChanged(at: cogs.revision)
    return value
  }

  // Written out, and `nonisolated`, per the rule at the top of
  // `CogDescriptor.swift`. Removing it crashes the release build.
  nonisolated deinit {}
}
