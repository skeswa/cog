#if DEBUG

/// One rendered cause in a quiescence warning crossing the package boundary.
package nonisolated enum CogQuiescenceCauseSnapshot: Sendable, Equatable {
  case turn(String)
  case reaction(String)
}

/// The last long uninterrupted drain this context warned about.
package nonisolated struct CogQuiescenceWarningSnapshot: Sendable, Equatable {
  package let uninterruptedTurnCount: Int
  package let causalChain: [CogQuiescenceCauseSnapshot]
  package let causalChainIsTruncated: Bool
}

/// The narrow behavior snapshot exposed to the `CogTesting` product.
package nonisolated struct CogQuiescenceDiagnosticSnapshot: Sendable, Equatable {
  package let warningCount: Int
  package let lastWarning: CogQuiescenceWarningSnapshot?
  package let isIdle: Bool
}

/// One unrendered step retained while a synchronous FIFO drain is active.
private enum CogQuiescenceTraceStep {
  case turn(String)
  case reaction(CogLabel)
}

/// DEBUG-only guard for a long turn → reaction → turn causal episode.
///
/// One episode begins when an idle caller starts an outer turn and ends only
/// when that same synchronous call has drained every queued write-back. The
/// structural turn phase becomes idle briefly between queued turns, so that
/// phase alone cannot delimit an uninterrupted episode.
internal struct CogQuiescenceTracker {
  private static let turnThreshold = 64
  private static let maximumCausalChainLength = 256

  private(set) var isActive = false
  private var completedTurnCount = 0
  private var causalChain: [CogQuiescenceTraceStep] = []
  private var causalChainIsTruncated = false
  private var warnedInActiveEpisode = false

  private(set) var warningCount = 0
  private(set) var lastWarning: CogQuiescenceWarningSnapshot?

  mutating func beginEpisode() {
    guard !isActive else {
      fatalError("Cog tried to begin a quiescence episode while one was already active.")
    }

    isActive = true
    completedTurnCount = 0
    causalChain.removeAll(keepingCapacity: true)
    causalChainIsTruncated = false
    warnedInActiveEpisode = false
  }

  mutating func endEpisode() {
    guard isActive else {
      fatalError("Cog tried to end a quiescence episode while none was active.")
    }

    isActive = false
    completedTurnCount = 0
    causalChain.removeAll(keepingCapacity: true)
    causalChainIsTruncated = false
    warnedInActiveEpisode = false
  }

  mutating func recordTurn(named name: String) {
    record(.turn(name))
  }

  mutating func recordReaction(label: CogLabel) {
    record(.reaction(label))
  }

  /// Completes one turn and emits the one warning allowed for this episode.
  mutating func completeTurn() {
    guard isActive else { return }
    completedTurnCount += 1

    guard !warnedInActiveEpisode, completedTurnCount > Self.turnThreshold else {
      return
    }

    warnedInActiveEpisode = true
    let warning = CogQuiescenceWarningSnapshot(
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
    logCogQuiescenceWarning(warning)
    warningCount += 1
    lastWarning = warning
  }

  func diagnostic(isIdle: Bool) -> CogQuiescenceDiagnosticSnapshot {
    CogQuiescenceDiagnosticSnapshot(
      warningCount: warningCount,
      lastWarning: lastWarning,
      isIdle: isIdle
    )
  }

  private mutating func record(_ step: CogQuiescenceTraceStep) {
    guard isActive, !warnedInActiveEpisode else { return }
    guard causalChain.count < Self.maximumCausalChainLength else {
      causalChainIsTruncated = true
      return
    }
    causalChain.append(step)
  }
}

extension Cogtext {
  /// The quiescence behavior a test may observe without seeing graph storage.
  package var quiescenceDiagnosticSnapshot: CogQuiescenceDiagnosticSnapshot {
    let phaseIsIdle: Bool
    if case .idle = turnPhase {
      phaseIsIdle = true
    } else {
      phaseIsIdle = false
    }

    return quiescenceTracker.diagnostic(
      isIdle: phaseIsIdle
        && queuedTurns.isEmpty
        && reactionRuns.isEmpty
        && trackedConsumer == nil
        && settleStack.isEmpty
        && seedBarrierDepth == 0
        && !quiescenceTracker.isActive
    )
  }
}

#endif
