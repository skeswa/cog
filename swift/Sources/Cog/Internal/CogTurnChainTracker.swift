#if DEBUG

/// One rendered cause in a turn-chain warning crossing the package boundary.
package nonisolated enum CogTurnChainCauseSnapshot: Sendable, Equatable {
  case turn(String)
  case reaction(String)
}

/// The last long turn chain this context warned about.
package nonisolated struct CogTurnChainWarningSnapshot: Sendable, Equatable {
  package let uninterruptedTurnCount: Int
  package let causalChain: [CogTurnChainCauseSnapshot]
  package let causalChainIsTruncated: Bool
}

/// The behavior snapshot exposed to `CogTesting`.
package nonisolated struct CogTurnChainDiagnosticSnapshot: Sendable, Equatable {
  package let warningCount: Int
  package let lastWarning: CogTurnChainWarningSnapshot?
  package let isIdle: Bool
}

/// One step kept while a turn chain runs.
private enum CogTurnChainTraceStep {
  case turn(String)
  case reaction(CogLabel)
}

/// Tracks one synchronous chain of turns and warns if it runs too long.
///
/// A chain starts with a commit made while the context is idle. If a reaction
/// writes state, that write becomes the next turn in the same chain. For
/// example: `turn A → reaction B → turn B`. The chain ends after all queued
/// writes finish and control returns to the caller.
internal struct CogTurnChainTracker {
  private static let turnThreshold = 64
  private static let maximumCausalChainLength = 256

  private(set) var isActive = false
  private var completedTurnCount = 0
  private var causalChain: [CogTurnChainTraceStep] = []
  private var causalChainIsTruncated = false
  private var warnedInActiveChain = false

  private(set) var warningCount = 0
  private(set) var lastWarning: CogTurnChainWarningSnapshot?

  mutating func beginChain() {
    guard !isActive else {
      fatalError("Cog tried to begin a turn chain while one was already active.")
    }

    isActive = true
    completedTurnCount = 0
    causalChain.removeAll(keepingCapacity: true)
    causalChainIsTruncated = false
    warnedInActiveChain = false
  }

  mutating func endChain() {
    guard isActive else {
      fatalError("Cog tried to end a turn chain while none was active.")
    }

    isActive = false
    completedTurnCount = 0
    causalChain.removeAll(keepingCapacity: true)
    causalChainIsTruncated = false
    warnedInActiveChain = false
  }

  mutating func recordTurn(named name: String) {
    record(.turn(name))
  }

  mutating func recordReaction(label: CogLabel) {
    record(.reaction(label))
  }

  /// Completes one turn and emits at most one warning for the active chain.
  mutating func completeTurn() {
    guard isActive else { return }
    completedTurnCount += 1

    guard !warnedInActiveChain, completedTurnCount > Self.turnThreshold else {
      return
    }

    warnedInActiveChain = true
    let warning = CogTurnChainWarningSnapshot(
      uninterruptedTurnCount: completedTurnCount,
      causalChain: causalChain.map { step in
        switch step {
        case .turn(let name):
          return .turn(name)
        case .reaction(let label):
          return .reaction("\(label)")
        }
      },
      causalChainIsTruncated: causalChainIsTruncated
    )
    logCogTurnChainWarning(warning)
    warningCount += 1
    lastWarning = warning
  }

  func diagnostic(isIdle: Bool) -> CogTurnChainDiagnosticSnapshot {
    CogTurnChainDiagnosticSnapshot(
      warningCount: warningCount,
      lastWarning: lastWarning,
      isIdle: isIdle
    )
  }

  private mutating func record(_ step: CogTurnChainTraceStep) {
    guard isActive, !warnedInActiveChain else { return }
    guard causalChain.count < Self.maximumCausalChainLength else {
      causalChainIsTruncated = true
      return
    }
    causalChain.append(step)
  }
}

extension Cogtext {
  /// The turn-chain behavior a test may observe without seeing graph storage.
  package var turnChainDiagnosticSnapshot: CogTurnChainDiagnosticSnapshot {
    let phaseIsIdle: Bool
    if case .idle = turnPhase {
      phaseIsIdle = true
    } else {
      phaseIsIdle = false
    }

    return turnChainTracker.diagnostic(
      isIdle: phaseIsIdle
        && queuedTurns.isEmpty
        && reactionRuns.isEmpty
        && trackedConsumer == nil
        && settleStack.isEmpty
        && seedBarrierDepth == 0
        && !turnChainTracker.isActive
    )
  }
}

#endif
