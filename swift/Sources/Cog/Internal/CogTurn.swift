/// An identity only Cog can mint for one turn.
///
/// Writers carry this object rather than an integer supplied by a caller. Its
/// object identity is the capability: a writer is valid only while its exact
/// token is the context's accumulating turn. The type and initializer are
/// internal, so application code cannot manufacture a matching token.
internal final class CogTurnID {}

/// The state of one turn while the context advances through it.
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

/// Where a context is in the structural commit boundary (§3.2).
internal enum CogTurnPhase {
  case idle
  case accumulating(CogTurn)
  case flushing(CogTurn)
}

// Every trap below is `fatalError` rather than `preconditionFailure` for the
// reason spelled out at `Cogtext.requireWriterTurn` in `Writer.swift`: an
// optimized `preconditionFailure` drops its message, and a guard that stops the
// program without saying why is barely a guard. Keep them `fatalError`.

extension Cogtext {
  /// Joins an accumulating turn, or runs one new outer turn through its flush.
  ///
  /// A nested commit receives the existing turn and returns without changing
  /// phase, so only the outermost body closes the structural write boundary.
  /// A sibling call arrives after that flush returned the context to idle and
  /// therefore mints its own turn. A call made while flushing appends its body
  /// to the non-reentrant FIFO drained by the active outer call. A call made
  /// during derived computation is rejected before any of those paths can run.
  internal func withTurn(_ name: String = #function, _ body: @escaping (CogTurn) -> Void) {
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
    quiescenceTracker.beginEpisode()
    defer { quiescenceTracker.endEpisode() }
    #endif

    runOuterTurn(named: name, body)
    drainQueuedTurns()
  }

  /// Runs exactly one idle → accumulating → flushing → idle transition.
  private func runOuterTurn(named name: String, _ body: (CogTurn) -> Void) {
    let turn = startTurn(named: name)
    body(turn)
    startFlushing(turn.id)
    turn.flushPendingSources(in: self)
    flushReactions()
    finishTurn(turn.id)

    #if DEBUG
    quiescenceTracker.completeTurn()
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

    // Recorded here, at the one place a turn is minted, so that every path
    // reaching a turn records exactly one entry: the outer commit, and the
    // FIFO drain's replay of a queued body. A nested commit returns from
    // `withTurn` above without arriving here, which is what makes a joined
    // commit one turn in history rather than two. Recorded at the start, so a
    // turn precedes the writes and recomputations it caused.
    #if DEBUG
    historyLog.recordTurn(named: name)
    quiescenceTracker.recordTurn(named: name)
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
