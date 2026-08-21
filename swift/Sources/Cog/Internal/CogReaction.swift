/// Whether a tracked terminal publishes an export or runs an application effect.
///
/// The phase is fixed at registration. Flushes use it to offer every changed
/// export after UI notices but before any mechanism reaction or watch runs.
internal enum CogReactionPhase: Equatable {
  /// A ``CogValues`` subscription whose body offers one settled value.
  case export

  /// A mechanism reaction or watch whose body performs application work.
  case effect
}

/// One tracked terminal registration owned by a context.
///
/// A reaction is a terminal consumer, not readable state. The arena gives it
/// one generated scalar row and keeps this object only for the effect closure,
/// registration order, cancellation identity, and cold lifetime bookkeeping.
/// The owning MainActor context runs it after UI settlement and keeps only the
/// durable automatic roots it directly reads externally leased. Export terminals
/// run before effect terminals within each flush; registration order remains
/// stable inside each phase.
internal final class CogReaction {
  /// The stable diagnostic identity supplied at registration.
  let label: CogLabel

  /// Which flush phase owns this terminal's body run.
  let phase: CogReactionPhase

  /// The context that owns this registration, or `nil` once it is gone.
  ///
  /// Weak because the context owns its registrations. A token may outlive an
  /// isolated test context without keeping that graph alive.
  private weak var cogs: Cogs?

  /// Generated value-less terminal receiving this reaction's arena edges.
  let arenaSlot: CogArenaSlot

  /// Whether cancellation or context teardown has retired `arenaSlot`.
  private var arenaSlotIsReleased = false

  /// Unique direct arena roots whose durable counts this reaction owns.
  ///
  /// The list is cold registration bookkeeping. Propagation still walks only
  /// integer edges and scalar columns; keeping exact generation-bearing slots
  /// here lets cancellation balance counts before returning the terminal row.
  private(set) var arenaLeasedDependencies: ContiguousArray<CogArenaSlot> = []

  /// Reused next-set buffer for allocation-free steady reaction retracking.
  private var arenaLeaseScratch: ContiguousArray<CogArenaSlot> = []

  /// Number of active body frames retaining this terminal through FIFO write-back.
  ///
  /// A reaction can trigger a later turn that reruns it before the outer call
  /// returns. Counting those frames keeps self-cancellation from retiring the
  /// shared slot until every nested run has unwound.
  private var runDepth = 0

  /// What this registration runs, until cancellation releases it.
  ///
  /// Cancellation clears the body and releases its captures immediately.
  private var body: (@MainActor (ReactionReader) -> Void)?

  /// Whether this registration has been stopped.
  private(set) var isCancelled = false

  /// Creates an inert registration; the context installs and initially runs it
  /// in registration order after ownership is established.
  init(
    cogs: Cogs,
    label: CogLabel,
    phase: CogReactionPhase,
    body: @escaping @MainActor (ReactionReader) -> Void
  ) {
    self.cogs = cogs
    self.label = label
    self.phase = phase
    self.body = body
    self.arenaSlot = cogs.arenaCore.allocateReaction()
  }

  /// Releases the closure and bookkeeping wherever the last owner runs.
  nonisolated deinit {}

  /// Stops this registration and takes it out of the graph.
  ///
  /// Remove both dependency edges and the context registration. Leaving either
  /// would retain graph state or keep later flushes scanning the reaction.
  ///
  /// Queued runs remain in the array, so every run checks `isCancelled`.
  ///
  /// `run(in:)` keeps an executing body in a local, so self-cancellation cannot
  /// release the closure on the stack.
  func cancel() {
    guard !isCancelled else { return }
    isCancelled = true
    releaseArenaLeases()
    body = nil

    if runDepth == 0 {
      releaseArenaSlotIfNeeded()
    }

    // Predicate removal also handles an already-removed registration and keeps
    // survivor order inside the terminal's phase.
    switch phase {
    case .export:
      cogs?.exportReactions.removeAll { $0 === self }
    case .effect:
      cogs?.reactions.removeAll { $0 === self }
    }
  }

  /// Balances arena leases during context teardown.
  ///
  /// This bypasses normal grace scheduling because no state in the context can
  /// survive the same isolated deinitialization pass.
  func releaseArenaLeasesForContextTeardown() {
    if let cogs {
      cogs.arenaCore.releaseReactionLeasesForContextTeardown(&arenaLeasedDependencies)
    } else {
      arenaLeasedDependencies.removeAll(keepingCapacity: true)
    }
    arenaLeaseScratch.removeAll(keepingCapacity: true)
  }

  /// Whether propagation has made this registration reachable.
  func needsFlush(in cogs: Cogs) -> Bool {
    guard !isCancelled else { return false }
    return cogs.arenaCore.reactionNeedsSettlement(arenaSlot)
  }

  /// Runs once at registration to establish the first dependency set.
  ///
  /// Initial runs share the active flush's ordered reaction queue when created
  /// during a turn, preventing them from overtaking already-invalidated effects.
  func runInitially(in cogs: Cogs) {
    run(in: cogs)
  }

  /// Settles the hot dependencies of a reachable reaction and reruns it only
  /// when at least one value changed since its last completed run.
  ///
  /// CHECK dependencies settle first. If they all prove equal, the arena stops
  /// work without invoking user code.
  func runIfNeeded(in cogs: Cogs) {
    guard needsFlush(in: cogs) else { return }

    let arenaDependencyChanged = cogs.arenaCore.settleReactionDependencies(
      arenaSlot,
      in: cogs
    )

    if arenaDependencyChanged {
      run(in: cogs)
    }
  }

  /// Captures a fresh dependency set around one synchronous body run.
  ///
  /// Dependency edges and lease ownership reconcile before capture completes.
  /// Any system turns requested by async reads inside the body drain only
  /// afterward, when tracking and the automatic computing path are both empty.
  private func run(in cogs: Cogs) {
    // Every run checks cancellation. The local keeps the closure alive through
    // self-cancellation.
    guard !isCancelled, let body = self.body else { return }

    // Record every terminal run, including initial offers and a watch's quiet
    // `.skip` install. Only effects participate in reaction write-back chain
    // diagnostics; an export merely offers into non-blocking stream storage.
    #if DEBUG
    switch phase {
    case .export:
      cogs.arenaCore.recordHistoryOffer(label: label)
    case .effect:
      cogs.arenaCore.recordHistoryEffect(label: label)
      cogs.turnChainTracker.recordReaction(label: label)
    }
    #endif

    runDepth += 1
    defer {
      runDepth -= 1
      if isCancelled, runDepth == 0 {
        releaseArenaSlotIfNeeded()
      }
    }
    cogs.arenaCore.captureReactionDependencies(for: arenaSlot) {
      body(ReactionReader(cogs: cogs, reaction: self))
    }

    if !isCancelled {
      cogs.arenaCore.reconcileReactionLeases(
        for: arenaSlot,
        current: &arenaLeasedDependencies,
        scratch: &arenaLeaseScratch,
        in: cogs
      )
    }

    cogs.arenaCore.completeReactionRun(arenaSlot)
    cogs.drainQueuedTurnsIfPossible()
  }

  /// Releases every arena lease at explicit cancellation or final token cleanup.
  private func releaseArenaLeases() {
    if let cogs {
      cogs.arenaCore.releaseReactionLeases(&arenaLeasedDependencies, in: cogs)
    } else {
      arenaLeasedDependencies.removeAll(keepingCapacity: true)
    }
    arenaLeaseScratch.removeAll(keepingCapacity: true)
  }

  /// Retires the generated terminal after capture has fully unwound.
  ///
  /// A token may outlive its context. In that case the context-owned arena is
  /// already gone and only this local idempotence bit remains to update.
  private func releaseArenaSlotIfNeeded() {
    guard !arenaSlotIsReleased else { return }
    cogs?.arenaCore.releaseReaction(arenaSlot)
    arenaSlotIsReleased = true
  }
}

/// One entry in the active flush's registration-ordered reaction queue.
///
/// Changed registrations precede initial registrations appended during that
/// flush. Each entry rechecks cancellation when performed, since cancellation
/// intentionally does not mutate the queue being iterated.
internal enum CogReactionRun {
  /// Reconsider a previously registered reaction after invalidation.
  case changed(CogReaction)

  /// Establish dependencies for a registration created during this flush.
  case initial(CogReaction)

  /// The flush phase of the terminal captured by this run.
  var phase: CogReactionPhase {
    switch self {
    case .changed(let reaction), .initial(let reaction):
      reaction.phase
    }
  }

  /// Performs the queued run using the mode captured when it was enqueued.
  func perform(in cogs: Cogs) {
    switch self {
    case .changed(let reaction):
      reaction.runIfNeeded(in: cogs)
    case .initial(let reaction):
      reaction.runInitially(in: cogs)
    }
  }
}
