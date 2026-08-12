/// The live state behind one ``Cog`` value reference, in one context.
///
/// A derived state gets its value by running its declaration's selector (§2.2).
///
/// Creation does not compute. The first read runs the selector, and later reads
/// use the cached value. CLEAN/CHECK/DIRTY state and versions keep that cache
/// current after writes. An equal rerun stops downstream work.
///
/// Each run records the dependencies it reads. Settlement walks those parents,
/// and the next run replaces the dependency set so branches and early returns
/// can change it.
internal final class DerivedCogState<Value>:
  CogState, CogConsumer, DerivedCogSettleState, CogLifetimeLeaseState
{
  /// The declaration this state belongs to.
  let descriptor: DerivedCogDescriptor<Value>

  /// Which state of `descriptor` this is, or `nil` for a keyless declaration.
  ///
  /// Used to print names such as `isNiceOutside[90210]` (§2.4).
  let key: AnyHashable?

  /// The declaration half of this state's stable descriptor-and-key identity.
  var descriptorIdentity: ObjectIdentifier { descriptor.identity }

  /// Whether this state currently appears on the context's computation path.
  ///
  /// The common cycle check is this one bit. The context scans its active path
  /// only after the bit says a read would close a cycle.
  var isComputing: Bool

  /// What the last run of the selector produced, or `.none` if it has never
  /// run in this context.
  ///
  /// The outer optional records whether the selector has run. For optional
  /// values, `.some(.none)` is a cached `nil`.
  internal private(set) var cachedValue: Value?

  /// The producers the last run read through `c.get`, in read order.
  ///
  /// Each run rebuilds this list in read order (§2.4). The correctness core
  /// keeps repeats; M6 may replace the layout after benchmarks (perf §3.3).
  internal private(set) var dependencies: [any CogState] = []

  /// Fresh derived states are DIRTY because they have no value to return yet.
  var settleState: CogSettleState

  /// The revision in which the cached value last changed.
  var changedAt: CogVersion

  /// The revision through which the cached value was last proved current.
  var checkedAt: CogVersion

  /// Consumers whose last run read this derived value.
  var subscribers: [CogSubscriberEdge]

  var label: CogLabel { descriptor.label }

  /// The declaration's lifetime policy, shared by every key of a box.
  var lifetime: CogStateLifetime { descriptor.lifetime }

  /// External consumers currently keeping this derived root observed.
  var externalLeaseCount: Int

  /// The descriptor-and-key identity this context files the state under.
  var stateIdentity: CogStateIdentity {
    CogStateIdentity(descriptor: descriptorIdentity, key: key)
  }

  /// Invalidates a pending grace completion when observation changes.
  var lifetimeReleaseGeneration: UInt64

  /// Whether the selector has run in this context yet.
  ///
  /// Exposes cache presence without exposing its representation.
  var hasComputed: Bool {
    if case .some = cachedValue {
      return true
    }
    return false
  }

  /// Creates the state without computing anything.
  init(descriptor: DerivedCogDescriptor<Value>, key: AnyHashable?) {
    self.descriptor = descriptor
    self.key = key
    self.cachedValue = .none
    self.isComputing = false
    self.settleState = .dirty
    self.changedAt = .initial
    self.checkedAt = .initial
    self.subscribers = []
    self.externalLeaseCount = 0
    self.lifetimeReleaseGeneration = 0
  }

  /// The state's value, running the selector if this is its first read.
  ///
  /// Every tracked or untracked read goes through this method, so no caller can
  /// skip first computation or settlement.
  func settledValue(in cogs: Cogtext) -> Value {
    if let cycle = cogs.settleStack.cyclePath(ifEntering: self) {
      fatalError(cycle.message)
    }

    if settleState != .clean {
      cogs.settle(self)
    }

    guard case .some(let cached) = cachedValue else {
      fatalError("A settled derived Cog lost its cached value.")
    }
    return cached
  }

  func recordDependency(on producer: any CogState) {
    dependencies.append(producer)
    producer.addSubscriber(self)
  }

  func releaseDependenciesForContextTeardown() {
    dependencies.removeAll()
  }

  func releaseDependenciesForLifetime() {
    for dependency in dependencies {
      dependency.removeSubscriber(self)
    }
    dependencies.removeAll()
  }

  /// Reruns the generic selector behind a type-erased settle exit frame.
  func recompute(in cogs: Cogtext) {
    _ = run(in: cogs)
  }

  /// Runs the selector once, tracking what it reads, and keeps the result.
  ///
  /// The state installs itself as the context's tracked consumer for the
  /// duration of the run, so a nested read of another derived cog computes
  /// that cog against *itself* and hands tracking back on the way out.
  private func run(in cogs: Cogtext) -> Value {
    guard isComputing else {
      fatalError("A derived Cog selector ran outside the settle computation path.")
    }

    #if DEBUG
    // Reader tracking ends before the user-supplied equality check below. Keep
    // debug seed blocked until the state has recorded the result, or a seed from
    // that equality closure could be cleaned over and leave this cache stale.
    cogs.seedBarrierDepth += 1
    defer { cogs.seedBarrierDepth -= 1 }
    #endif

    // Record at the selector call so lazy first runs and equal reruns appear in
    // history.
    #if DEBUG
    cogs.historyLog.recordRecompute(label: label, key: key)
    #endif

    let previousValue = cachedValue
    let previousDependencies = dependencies
    dependencies.removeAll(keepingCapacity: true)

    let value = cogs.tracking(self) {
      descriptor.compute(Reader(cogs: cogs, state: self), key: key)
    }

    for previousDependency in previousDependencies
    where !dependencies.contains(where: { $0 === previousDependency }) {
      previousDependency.removeSubscriber(self)
    }

    if case .some(let previousValue) = previousValue,
      descriptor.valuesAreEqual(previousValue, value)
    {
      // The state is current, but its value did not change. Preserve
      // `changedAt` so CHECK consumers can stay cached.
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
