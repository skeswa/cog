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
/// can change it. Lifetime release removes a whole unobserved dependency closure
/// without treating its internal graph edges as durable observation.
/// The context owns this object in its descriptor-and-key map and confines its
/// cache, edges, lease bookkeeping, and computation markers to the MainActor.
internal final class DerivedCogState<Value>:
  CogState, CogConsumer, CogReaderState, DerivedCogSettleState, CogLifetimeLeaseState,
  CogObservationState
{
  /// The declaration this state belongs to.
  let descriptor: DerivedCogDescriptor<Value>

  /// Which state of `descriptor` this is, or `nil` for a keyless declaration.
  ///
  /// Used to print names such as `isNiceOutside[90210]` (§2.4).
  /// Together with descriptor object identity, the key also determines storage
  /// identity and remains fixed until this state is released.
  let key: CogKey?

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

  /// The last completed cached value available to `Reader.curr`.
  var readerCurrentValue: Value? { cachedValue }

  /// The producers the last run read through `c[valueReference]`, in read order.
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

  /// Created only after this exact descriptor-and-key state reaches the UI.
  var observationBoundary: CogObservationBoundary?

  /// The erased key rendered with UI notice history for this boundary.
  var observationKey: CogKey? { key }

  /// The declaration label used for diagnostics, history, and UI notices.
  var label: CogLabel { descriptor.label }

  /// The declaration's lifetime policy, shared by every key of a box.
  var lifetime: CogStateLifetime { descriptor.lifetime }

  /// Exact reaction-owned consumers currently keeping this derived root observed.
  ///
  /// A UI boundary pins separately, and internal subscribers never increment
  /// this count.
  var externalLeaseCount: Int

  /// The descriptor-and-key identity this context files the state under.
  var stateIdentity: CogStateIdentity {
    CogStateIdentity(descriptor: descriptorIdentity, key: key)
  }

  /// Invalidates a pending grace completion when observation changes.
  ///
  /// The sleeping task captures one generation and must still match before it
  /// can remove this exact state.
  var lifetimeReleaseGeneration: UInt64

  /// The scheduled grace generation whose deadline has not arrived yet.
  ///
  /// The expiry task clears this marker before testing subscribers. If an
  /// internal consumer kept the state alive past that point, removing that
  /// consumer may cascade release immediately instead of scheduling fresh grace.
  var pendingLifetimeReleaseGeneration: UInt64?

  /// The single cancellable task waiting for this state's current deadline.
  ///
  /// A new demand cancels and clears it; generation validation still protects
  /// against a wake racing cancellation.
  var lifetimeReleaseTask: Task<Void, Never>?

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
  init(descriptor: DerivedCogDescriptor<Value>, key: CogKey?) {
    self.descriptor = descriptor
    self.key = key
    self.cachedValue = .none
    self.isComputing = false
    self.settleState = .dirty
    self.changedAt = .initial
    self.checkedAt = .initial
    self.subscribers = []
    self.observationBoundary = nil
    self.externalLeaseCount = 0
    self.lifetimeReleaseGeneration = 0
    self.pendingLifetimeReleaseGeneration = nil
    self.lifetimeReleaseTask = nil
  }

  /// The state's value, running the selector if this is its first read.
  ///
  /// Every tracked or untracked read goes through this method, so no caller can
  /// skip first computation or settlement.
  func settledValue(in cogs: Cogs) -> Value {
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

  /// Records one selector read and installs its reverse invalidation edge.
  ///
  /// Repeated reads remain in dependency order but `addSubscriber` keeps one
  /// weak reverse edge for this consumer.
  func recordDependency(on producer: any CogState) {
    dependencies.append(producer)
    producer.addSubscriber(self)
  }

  /// Breaks strong forward edges before the entire context is deallocated.
  ///
  /// Every producer is ending too, so reverse-edge repair is unnecessary. This
  /// flat prepass prevents ARC from recursively destroying a deep derived chain.
  func releaseDependenciesForContextTeardown() {
    dependencies.removeAll()
  }

  /// Severs both sides of dependency edges before this one state is removed.
  ///
  /// Producers survive ordinary lifetime release. Removing their reverse edge
  /// keeps invalidation correct and can make an already-expired, unobserved
  /// producer eligible for the same release cascade.
  func releaseDependenciesForLifetime() {
    for dependency in dependencies {
      dependency.removeSubscriber(self)
    }
    dependencies.removeAll()
  }

  /// Reruns the generic selector behind a type-erased settle exit frame.
  ///
  /// By the time the exit frame calls this, dirty parents have settled and this
  /// state is on the active computation path for cycle and write rejection.
  func recompute(in cogs: Cogs) {
    _ = run(in: cogs)
  }

  /// Runs the selector once, tracking what it reads, and keeps the result.
  ///
  /// The state installs itself as the context's tracked consumer for the
  /// duration of the run, so a nested read of another derived cog computes that
  /// cog against *itself* and hands tracking back on the way out. The completed
  /// run then removes reverse edges for abandoned branches before equality can
  /// stop the downstream wave.
  private func run(in cogs: Cogs) -> Value {
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
    cogs.recordHistoryRecompute(label: label, key: key)
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
