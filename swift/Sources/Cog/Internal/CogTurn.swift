// A turn is one synchronous, atomic state change started by `Cogtext.commit`.
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
// A nested commit joins the accumulating turn. A commit opened by a reaction
// waits in a FIFO queue because the current turn is already flushing.

/// An identity only Cog can mint for one turn.
///
/// Object identity ties a writer to the context's accumulating turn.
/// Application code cannot construct a matching token.
internal final class CogTurnID {}

/// The writes and identity collected while one turn runs.
internal final class CogTurn {
  let id: CogTurnID
  let name: String

  /// Sources written while this turn accumulates. Repeated entries are safe:
  /// the first flush consumes the one pending slot and later entries are
  /// no-ops. A future measured representation may deduplicate this work.
  private var touchedSources: [any PendingCogSource] = []

  init(id: CogTurnID, name: String) {
    self.id = id
    self.name = name
  }

  func touch(_ source: any PendingCogSource) {
    touchedSources.append(source)
  }

  func flushPendingSources(in cogs: Cogtext) {
    let revision = cogs.advanceRevision()
    for source in touchedSources {
      source.flushPendingValue(in: cogs, at: revision)
    }
    touchedSources.removeAll(keepingCapacity: true)
  }
}

/// One commit body waiting for the active flush to finish.
internal struct QueuedCogTurn {
  let name: String
  let body: (CogTurn) -> Void
}

/// Where a context is in its turn lifecycle.
internal enum CogTurnPhase {
  case idle
  case accumulating(CogTurn)
  case flushing(CogTurn)
}

// Keep these as `fatalError`; `preconditionFailure` drops its message under
// optimization. See `Cogtext.requireWriterTurn` in `Writer.swift`.

extension Cogtext {
  /// Rejects an application operation before it can open a turn during derivation.
  internal func requireOutsideDerivedComputation(forTurnNamed name: String) {
    if let computing = settleStack.innermostComputingState {
      let cogName = CogCycleStep(state: computing).name
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
  /// Async phase publication originates from derived computation itself. It is
  /// still a named turn, but it is not an application write and therefore may
  /// be requested while the async selector is on the computation path.
  internal func withSystemTurn(_ name: String, _ body: @escaping (CogTurn) -> Void) {
    switch turnPhase {
    case .idle:
      #if DEBUG
      turnChainTracker.beginChain()
      defer { turnChainTracker.endChain() }
      #endif

      runOuterTurn(named: name, body)
      drainQueuedTurns()

    case .accumulating, .flushing:
      queuedTurns.append(QueuedCogTurn(name: name, body: body))
    }
  }

  /// Joins an accumulating turn, or runs one new outer turn through its flush.
  ///
  /// Nested commits join the turn. Sibling commits start separate turns.
  /// Commits during flush enter the FIFO queue. Derived computation rejects a
  /// commit before any of these paths run.
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
  private func drainQueuedTurns() {
    var index = 0
    while index < queuedTurns.count {
      let queued = queuedTurns[index]
      index += 1
      runOuterTurn(named: queued.name, queued.body)
    }
    queuedTurns.removeAll(keepingCapacity: true)
  }

  /// Starts a new outer turn.
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
    historyLog.recordTurn(named: name)
    turnChainTracker.recordTurn(named: name)
    #endif

    return turn
  }

  /// Closes the write boundary and begins the settled flush.
  internal func startFlushing(_ id: CogTurnID) {
    guard case .accumulating(let turn) = turnPhase, turn.id === id else {
      fatalError("Only the context's accumulating Cog turn can start its flush.")
    }

    turnPhase = .flushing(turn)
  }

  /// Returns the context to idle after the turn has fully flushed.
  internal func finishTurn(_ id: CogTurnID) {
    guard case .flushing(let turn) = turnPhase, turn.id === id else {
      fatalError("Only the context's flushing Cog turn can finish.")
    }

    turnPhase = .idle
  }
}
