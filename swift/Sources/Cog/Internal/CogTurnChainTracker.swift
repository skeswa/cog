#if DEBUG

/// One rendered cause in a turn-chain warning crossing the package boundary.
package nonisolated enum CogTurnChainCauseSnapshot: Sendable, Equatable {
  /// One named outer application or system turn.
  case turn(String)
  /// One reaction body that ran in the chain.
  case reaction(String)
}

/// The last long turn chain this context warned about.
package nonisolated struct CogTurnChainWarningSnapshot: Sendable, Equatable {
  /// Number of completed outer turns when the warning threshold was crossed.
  package let uninterruptedTurnCount: Int
  /// Bounded causal prefix in execution order.
  package let causalChain: [CogTurnChainCauseSnapshot]
  /// Whether causes after the retained prefix were omitted.
  package let causalChainIsTruncated: Bool
}

/// The behavior snapshot exposed to `CogTesting`.
package nonisolated struct CogTurnChainDiagnosticSnapshot: Sendable, Equatable {
  /// Total warnings emitted by this context.
  package let warningCount: Int
  /// The latest warning, or `nil` before any chain crosses the threshold.
  package let lastWarning: CogTurnChainWarningSnapshot?
  /// Whether all turn, tracking, settlement, reaction, and debug barriers are idle.
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
/// writes finish and control returns to the caller. Graph-owned system turns
/// use the same accounting, including those deferred until selector or reaction
/// tracking unwinds. The tracker exists only in DEBUG and owns rendered trace
/// metadata, never graph state.
internal struct CogTurnChainTracker {
  private static let turnThreshold = 64
  private static let maximumCausalChainLength = 256

  /// Whether one synchronous outer-turn/FIFO chain is currently being measured.
  private(set) var isActive = false
  private var completedTurnCount = 0
  private var causalChain: [CogTurnChainTraceStep] = []
  private var causalChainIsTruncated = false
  private var warnedInActiveChain = false

  /// Number of threshold warnings emitted over this context's lifetime.
  private(set) var warningCount = 0
  /// Most recent bounded warning snapshot retained for `CogTesting`.
  private(set) var lastWarning: CogTurnChainWarningSnapshot?

  /// Opens a fresh synchronous chain and resets its bounded trace.
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

  /// Closes the active chain after every FIFO turn has returned to idle.
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

  /// Appends one named turn cause while the trace still accepts causes.
  mutating func recordTurn(named name: String) {
    record(.turn(name))
  }

  /// Appends one reaction cause without rendering its label on the hot path.
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

  /// Copies the retained warning behavior and caller-computed graph-idle state.
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

extension Cogs {
  /// The turn-chain behavior a test may observe without seeing graph storage.
  ///
  /// Idle is deliberately stronger than `turnPhase == .idle`: queued system
  /// turns, a popped-but-computing settle path, consumer tracking, reaction work,
  /// or an active debug chain all mean observable synchronous work remains.
  package var turnChainDiagnosticSnapshot: CogTurnChainDiagnosticSnapshot {
    let phaseIsIdle: Bool
    if case .idle = turnPhase {
      phaseIsIdle = true
    } else {
      phaseIsIdle = false
    }

    #if COG_CORE_ARENA
    let selectedCoreIsIdle = arenaCore.isSettlementIdle
    #else
    let selectedCoreIsIdle = settleStack.isEmpty && settleStack.isComputingEmpty
    #endif

    return turnChainTracker.diagnostic(
      isIdle: phaseIsIdle
        && queuedTurns.isEmpty
        && reactionRuns.isEmpty
        && trackedConsumer == nil
        && selectedCoreIsIdle
        && seedBarrierDepth == 0
        && !turnChainTracker.isActive
    )
  }
}

#endif
