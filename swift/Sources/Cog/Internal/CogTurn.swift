/// An identity only Cog can mint for one turn.
///
/// Writers carry this object rather than an integer supplied by a caller. Its
/// object identity is the capability: a writer is valid only while its exact
/// token is the context's accumulating turn. The type and initializer are
/// internal, so application code cannot manufacture a matching token.
internal final class CogTurnID {}

/// The stable facts about one turn while the context advances through it.
internal struct CogTurn {
  let id: CogTurnID
  let name: String
}

/// Where a context is in the structural commit boundary (§3.2).
internal enum CogTurnPhase {
  case idle
  case accumulating(CogTurn)
  case flushing(CogTurn)
}

extension Cogtext {
  /// Runs the accumulating body and the empty correctness-core flush for one
  /// outer turn. Later tasks put source settlement and graph work between the
  /// two final transitions without changing the commit boundary.
  internal func withTurn(_ name: String = #function, _ body: (CogTurn) -> Void) {
    let turn = startTurn(named: name)
    body(turn)
    startFlushing(turn.id)
    finishTurn(turn.id)
  }

  /// Starts a new outer turn.
  @discardableResult
  internal func startTurn(named name: String) -> CogTurn {
    guard case .idle = turnPhase else {
      preconditionFailure("A new outer Cog turn can start only while its context is idle.")
    }

    let turn = CogTurn(id: CogTurnID(), name: name)
    turnPhase = .accumulating(turn)
    return turn
  }

  /// Closes the write boundary and begins the settled flush.
  internal func startFlushing(_ id: CogTurnID) {
    guard case .accumulating(let turn) = turnPhase, turn.id === id else {
      preconditionFailure("Only the context's accumulating Cog turn can start its flush.")
    }

    turnPhase = .flushing(turn)
  }

  /// Returns the context to idle after the turn has fully flushed.
  internal func finishTurn(_ id: CogTurnID) {
    guard case .flushing(let turn) = turnPhase, turn.id === id else {
      preconditionFailure("Only the context's flushing Cog turn can finish.")
    }

    turnPhase = .idle
  }
}
