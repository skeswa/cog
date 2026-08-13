/// The live state behind one ``AsyncCog`` value reference in one context.
internal final class AsyncCogState<Value>:
  CogState, CogConsumer, CogReaderState, DerivedCogSettleState, CogLifetimeLeaseState,
  CogObservationState, PendingCogSource
{
  let descriptor: AsyncCogDescriptor<Value>
  let key: AnyHashable?

  var descriptorIdentity: ObjectIdentifier { descriptor.identity }
  var isComputing = false
  internal private(set) var dependencies: [any CogState] = []
  var settleState: CogSettleState = .dirty
  var changedAt: CogVersion = .initial
  var checkedAt: CogVersion = .initial
  var subscribers: [CogSubscriberEdge] = []
  var observationBoundary: CogObservationBoundary?
  var observationKey: AnyHashable? { key }
  var label: CogLabel { descriptor.label }
  var lifetime: CogStateLifetime { descriptor.lifetime }
  var externalLeaseCount = 0
  var lifetimeReleaseGeneration: UInt64 = 0
  var stateIdentity: CogStateIdentity {
    CogStateIdentity(descriptor: descriptorIdentity, key: key)
  }

  /// The first pending phase is staged through a normal named turn.
  private var pendingPhase: CogPhase<Value>?

  /// The phase returned to readers after its publication turn.
  private var phase: CogPhase<Value>?

  /// The last value work completed successfully, including an optional nil.
  private var lastSuccess: Previous<Value> = .none

  /// Work started by the first read.
  private var activeTask: Task<Void, Never>?

  var readerCurrentValue: CogPhase<Value>? { phase }

  init(descriptor: AsyncCogDescriptor<Value>, key: AnyHashable?) {
    self.descriptor = descriptor
    self.key = key
  }

  func settledPhase(in cogs: Cogtext) -> CogPhase<Value> {
    if let cycle = cogs.settleStack.cyclePath(ifEntering: self) {
      fatalError(cycle.message)
    }

    if settleState != .clean {
      cogs.settle(self)
    }

    guard let phase else {
      fatalError("A settled async Cog lost its phase.")
    }
    return phase
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

  func recompute(in cogs: Cogtext) {
    startWork(in: cogs)
  }

  private func startWork(in cogs: Cogtext) {
    guard isComputing else {
      fatalError("An async Cog selector ran outside the settle computation path.")
    }

    let previousDependencies = dependencies
    dependencies.removeAll(keepingCapacity: true)
    let work = cogs.tracking(self) {
      descriptor.makeWork(Reader(cogs: cogs, state: self), key: key)
    }

    for previousDependency in previousDependencies
    where !dependencies.contains(where: { $0 === previousDependency }) {
      previousDependency.removeSubscriber(self)
    }

    let pending = CogPhase<Value>.pending(previous: lastSuccess)
    if phase == nil {
      switch cogs.turnPhase {
      case .idle:
        stage(pending, named: "pending", in: cogs)
      case .accumulating, .flushing:
        // A first read must synchronously return honest pending state. Nothing
        // can already subscribe to a state with no phase, so install it now and
        // queue the named, otherwise-empty publication turn behind the active
        // turn without invalidating the reader that is establishing its baseline.
        phase = pending
        markChanged(at: cogs.revision)
        cogs.withSystemTurn("\(renderedName) pending") { _ in }
      }
    } else {
      // A dependency-triggered reload starts as a later turn. While the source
      // turn is still flushing, readers continue to see its last completed
      // phase; the queued pending turn invalidates them in turn order.
      let publishesSynchronously: Bool
      if case .idle = cogs.turnPhase {
        publishesSynchronously = true
      } else {
        publishesSynchronously = false
      }
      stage(pending, named: "pending", in: cogs)
      if !publishesSynchronously {
        markChecked(at: cogs.revision)
      }
    }

    let operation = work.operation
    activeTask?.cancel()
    activeTask = Task(name: renderedName) { @MainActor [weak self, weak cogs] in
      do {
        let value = try await operation()
        guard let self, let cogs else { return }
        self.lastSuccess = .some(value)
        self.publish(.success(value), named: "success", in: cogs)
      } catch {
        guard !Task.isCancelled else { return }
        guard let self, let cogs else { return }
        self.publish(.failure(error, previous: .none), named: "failure", in: cogs)
      }
    }
  }

  /// Publishes one completed work result as its own named turn.
  private func publish(_ phase: CogPhase<Value>, named phaseName: String, in cogs: Cogtext) {
    activeTask = nil
    stage(phase, named: phaseName, in: cogs)
  }

  /// Stages one phase into a named graph-owned turn.
  private func stage(_ phase: CogPhase<Value>, named phaseName: String, in cogs: Cogtext) {
    cogs.withSystemTurn("\(renderedName) \(phaseName)") { turn in
      self.pendingPhase = phase
      turn.touch(self)
    }
  }

  func flushPendingValue(in cogs: Cogtext, at revision: CogVersion) {
    guard let pendingPhase else { return }
    self.pendingPhase = nil
    phase = pendingPhase
    markChanged(at: revision)
    cogs.invalidateSubscribers(of: self)
  }

  private var renderedName: String {
    guard let key else { return "\(label)" }
    return "\(label)[\(key.base)]"
  }

  // Written out, and `nonisolated`, per the generic-class release rule.
  nonisolated deinit {}
}
