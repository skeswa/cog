// A turn is one synchronous, atomic state publication. Application turns begin
// at `Cogs.commit`; graph-owned system turns publish async status through the
// same flush machinery without pretending to be application writes.
//
// For example, if a commit writes `firstName` and `lastName`, its body stages
// both values. The flush then publishes both together, settles affected cogs,
// and runs reactions. Normal readers see the old pair before the flush and the
// new pair after it, never half of the update.
//
// A turn moves through two phases:
//
//   idle → accumulating writes → flushing changes and reactions → idle
//
// A nested commit joins the accumulating turn. Any application or system turn
// requested while flushing waits in one FIFO because consumers must finish the
// current completed revision before another becomes visible.

/// An identity only Cog can mint for one turn.
///
/// Object identity ties a writer to the context's accumulating turn and prevents
/// an escaped writer from operating in a later turn. Application code cannot
/// construct a matching token.
internal final class CogTurnID {}

/// The staged sources and identity collected while one turn accumulates.
///
/// Manual values and async status both conform to the pending-source contract,
/// so one ordered flush can assign a single revision before invalidation reaches
/// Observation boundaries and reactions.
internal final class CogTurn {
  /// The unforgeable capability owned by writers for this exact turn.
  let id: CogTurnID

  /// The diagnostic and history name of this outer turn.
  let name: String

  /// Sources written while this turn accumulates. Repeated entries are safe:
  /// the first flush consumes the one pending slot and later entries are
  /// no-ops. A future measured representation may deduplicate this work.
  private var touchedSources: [any PendingCogSource] = []

  #if COG_CORE_ARENA
  /// Arena source slots touched once in writer order by this turn.
  private var touchedArenaSources: ContiguousArray<CogArenaSlot> = []
  #endif

  /// Creates one accumulating turn with its unforgeable writer capability.
  init(id: CogTurnID, name: String) {
    self.id = id
    self.name = name
  }

  /// Registers a source whose staged slot must become visible in this turn.
  ///
  /// A repeated touch is harmless because the first flush consumes the slot;
  /// retaining duplicates keeps the correctness core simple until benchmarks
  /// justify deduplication.
  func touch(_ source: any PendingCogSource) {
    touchedSources.append(source)
  }

  #if COG_CORE_ARENA
  /// Registers one arena source whose pending typed cell must be published.
  ///
  /// ``CogArenaStateFlags/touched`` performs row-level deduplication before
  /// this method, keeping the flush list O(changed sources) without hashing.
  func touchArenaSource(_ source: CogArenaSlot) {
    touchedArenaSources.append(source)
  }
  #endif

  /// Publishes all staged slots under one newly assigned graph revision.
  ///
  /// Revision advances even for an empty system turn because the named pending
  /// transition remains part of global turn order. Each source decides whether
  /// its staged value changes and which consumers to invalidate.
  func flushPendingSources(in cogs: Cogs) {
    let revision = cogs.advanceRevision()
    #if COG_CORE_ARENA
    cogs.arenaCore.flushPendingSources(touchedArenaSources)
    touchedArenaSources.removeAll(keepingCapacity: true)
    #endif
    for source in touchedSources {
      source.flushPendingValue(in: cogs, at: revision)
    }
    touchedSources.removeAll(keepingCapacity: true)
  }
}

/// One application or system turn body waiting for the active flush to finish.
///
/// Bodies are retained in arrival order and receive a fresh turn only after the
/// current flush, including all reactions, has returned the context to idle.
internal struct QueuedCogTurn {
  /// The history and diagnostic name preserved from the requesting operation.
  let name: String
  /// The deferred staging body, executed only in its fresh accumulating turn.
  let body: (CogTurn) -> Void
}

/// Where a context is in its turn lifecycle.
///
/// Accumulation permits nested application writes to join atomically. Flushing
/// closes writer mutation; new turns queue instead of re-entering propagation.
internal enum CogTurnPhase {
  /// No body, publication, Observation flush, or reaction flush is active.
  case idle
  /// An open writer boundary accepting nested writes into the same atomic turn.
  case accumulating(CogTurn)
  /// A closed writer boundary publishing and propagating one completed revision.
  case flushing(CogTurn)
}

// Keep these as `fatalError`; `preconditionFailure` drops its message under
// optimization. See `Cogs.requireWriterTurn` in `Writer.swift`.

extension Cogs {
  /// Whether a graph-owned turn can flush without reentering graph evaluation.
  ///
  /// An idle context is not sufficient: a selector or reaction may be tracking
  /// outside a turn. System publication waits until both tracking and settlement
  /// have completed, so Observation and reactions never run through an active
  /// consumer. Both settle representations are checked because a popped exit
  /// frame leaves its derived state on the computing path through recomputation.
  internal var canRunSystemTurnImmediately: Bool {
    guard case .idle = turnPhase else { return false }
    guard settleStack.isEmpty && settleStack.isComputingEmpty && trackedConsumer == nil else {
      return false
    }
    #if COG_CORE_ARENA
    return arenaCore.isSettlementIdle
    #else
    return true
    #endif
  }

  /// Rejects an application operation before it can open a turn during derivation.
  ///
  /// The guard happens before state lookup or body execution. That keeps the
  /// whole selector region—including dependency reconciliation and equality—
  /// read-only and prevents a failed attempt from partially mutating the graph.
  internal func requireOutsideDerivedComputation(forTurnNamed name: String) {
    #if COG_CORE_ARENA
    let computingName = arenaCore.innermostComputingName
    #else
    let computingName = settleStack.innermostComputingState.map { CogCycleStep(state: $0).name }
    #endif
    if let cogName = computingName {
      fatalError(
        """
        Cog cannot commit turn \(String(reflecting: name)) while derived cog \(cogName) is \
        computing. Derived computation may only read Cog state. Invoke this op outside \
        derived computation, from event handling or a reaction.
        """
      )
    }
  }

  /// Runs one graph-owned turn without applying the public commit guard.
  ///
  /// Async status publication originates from derived computation itself. It is
  /// still a named turn, but it is not an application write and therefore may
  /// be requested while the async selector is on the computation path. This
  /// exception is internal-only: it must stage runtime-owned status, never
  /// invoke an application operation or expose a writer.
  ///
  /// If another turn is active, queue rather than nest a flush. That preserves
  /// completed-turn reads and ensures pending, success, and failure each occupy
  /// their own visible revision. The same deferral applies while otherwise-idle
  /// selector or reaction tracking is active; the first safe outer boundary
  /// drains the preserved name and body in FIFO order.
  internal func withSystemTurn(_ name: String, _ body: @escaping (CogTurn) -> Void) {
    guard canRunSystemTurnImmediately else {
      queuedTurns.append(QueuedCogTurn(name: name, body: body))
      return
    }

    #if DEBUG
    turnChainTracker.beginChain()
    defer { turnChainTracker.endChain() }
    #endif

    runOuterTurn(named: name, body)
    drainQueuedTurns()
  }

  /// Drains deferred system publication at the first safe graph boundary.
  ///
  /// The queue also carries turns requested during an active flush; those stay
  /// owned by that outer turn and fail this guard until it returns to idle.
  /// Settlement and reaction completion both call this method because either
  /// can be the outermost synchronous scope that requested the deferred turn.
  internal func drainQueuedTurnsIfPossible() {
    guard !queuedTurns.isEmpty, canRunSystemTurnImmediately else { return }

    #if DEBUG
    turnChainTracker.beginChain()
    defer { turnChainTracker.endChain() }
    #endif

    drainQueuedTurns()
  }

  /// Joins an accumulating turn, or runs one new outer turn through its flush.
  ///
  /// Nested commits join the turn so a call tree still publishes atomically.
  /// Sibling commits start separate turns. Commits during flush enter the FIFO
  /// queue, allowing reaction write-back without reentrant propagation. Derived
  /// computation rejects a commit before any of these paths run.
  internal func withTurn(_ name: String = #function, _ body: @escaping (CogTurn) -> Void) {
    requireOutsideDerivedComputation(forTurnNamed: name)

    switch turnPhase {
    case .accumulating(let turn):
      body(turn)
      return

    case .flushing:
      queuedTurns.append(QueuedCogTurn(name: name, body: body))
      return

    case .idle:
      break
    }

    #if DEBUG
    turnChainTracker.beginChain()
    defer { turnChainTracker.endChain() }
    #endif

    runOuterTurn(named: name, body)
    drainQueuedTurns()
  }

  /// Runs one idle → accumulating → flushing → idle transition.
  ///
  /// Flush order is part of correctness: publish staged state, settle and notify
  /// UI roots, run reactions against that completed revision, then return idle.
  /// Reactions may enqueue write-back or async publication, but none may reenter
  /// this sequence; the caller drains them after `finishTurn`.
  private func runOuterTurn(named name: String, _ body: (CogTurn) -> Void) {
    let turn = startTurn(named: name)
    body(turn)
    startFlushing(turn.id)
    turn.flushPendingSources(in: self)
    flushObservationBoundaries()
    flushReactions()
    finishTurn(turn.id)

    #if DEBUG
    turnChainTracker.completeTurn()
    #endif
  }

  /// Runs queued turns in arrival order without recursively entering a flush.
  ///
  /// The indexed loop intentionally observes bodies appended by reactions in a
  /// queued turn, preserving one non-reentrant FIFO until the chain is empty.
  /// Queue removal is delayed until all captured and newly appended entries have
  /// run, so mutating the array during reaction write-back cannot invalidate the
  /// current iteration index.
  private func drainQueuedTurns() {
    var index = 0
    while index < queuedTurns.count {
      let queued = queuedTurns[index]
      index += 1
      runOuterTurn(named: queued.name, queued.body)
    }
    queuedTurns.removeAll(keepingCapacity: true)
  }

  /// Starts a new outer turn while the context is idle.
  ///
  /// Only outer turns get a history entry and chain record; nested commits share
  /// their accumulating turn and therefore do not manufacture extra revisions.
  @discardableResult
  internal func startTurn(named name: String) -> CogTurn {
    guard case .idle = turnPhase else {
      fatalError("A new outer Cog turn can start only while its context is idle.")
    }

    let turn = CogTurn(id: CogTurnID(), name: name)
    turnPhase = .accumulating(turn)

    // Record when the turn is created. Nested commits do not reach this point,
    // and the entry precedes the work it caused.
    #if DEBUG
    recordHistoryTurn(named: name)
    turnChainTracker.recordTurn(named: name)
    #endif

    return turn
  }

  /// Closes the writer boundary and begins publication and propagation.
  internal func startFlushing(_ id: CogTurnID) {
    guard case .accumulating(let turn) = turnPhase, turn.id === id else {
      fatalError("Only the context's accumulating Cog turn can start its flush.")
    }

    turnPhase = .flushing(turn)
  }

  /// Returns the context to idle only after publication and reactions finish.
  internal func finishTurn(_ id: CogTurnID) {
    guard case .flushing(let turn) = turnPhase, turn.id === id else {
      fatalError("Only the context's flushing Cog turn can finish.")
    }

    turnPhase = .idle
  }
}
