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
  /// no-ops. A later equality-gating task can deduplicate this work.
  private var touchedSources: [any PendingCogSource] = []

  init(id: CogTurnID, name: String) {
    self.id = id
    self.name = name
  }

  func touch(_ source: any PendingCogSource) {
    touchedSources.append(source)
  }

  func flushPendingSources() {
    for source in touchedSources {
      source.flushPendingValue()
    }
    touchedSources.removeAll(keepingCapacity: true)
  }
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
  /// Runs the accumulating body and the empty correctness-core flush for one
  /// outer turn. Later tasks put source settlement and graph work between the
  /// two final transitions without changing the commit boundary.
  internal func withTurn(_ name: String = #function, _ body: (CogTurn) -> Void) {
    let turn = startTurn(named: name)
    body(turn)
    startFlushing(turn.id)
    turn.flushPendingSources()
    finishTurn(turn.id)
  }

  /// Starts a new outer turn.
  @discardableResult
  internal func startTurn(named name: String) -> CogTurn {
    guard case .idle = turnPhase else {
      fatalError("A new outer Cog turn can start only while its context is idle.")
    }

    let turn = CogTurn(id: CogTurnID(), name: name)
    turnPhase = .accumulating(turn)
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
