#if DEBUG

public import Cog

/// One turn or reaction in a long synchronous causal chain.
public nonisolated enum CogTurnChainCause: Sendable, Equatable {
  case turn(String)
  case reaction(String)
}

/// One DEBUG warning produced by a long turn chain.
public nonisolated struct CogTurnChainWarning: Sendable, Equatable {
  public let uninterruptedTurnCount: Int
  public let causalChain: [CogTurnChainCause]
  public let causalChainIsTruncated: Bool

  fileprivate init(_ snapshot: CogTurnChainWarningSnapshot) {
    uninterruptedTurnCount = snapshot.uninterruptedTurnCount
    causalChain = snapshot.causalChain.map { cause in
      switch cause {
      case .turn(let name):
        return .turn(name)
      case .reaction(let name):
        return .reaction(name)
      }
    }
    causalChainIsTruncated = snapshot.causalChainIsTruncated
  }
}

/// DEBUG-only behavior exposed by the turn-chain diagnostic seam.
public nonisolated struct CogTurnChainDiagnostic: Sendable, Equatable {
  public let warningCount: Int
  public let lastWarning: CogTurnChainWarning?
  public let isIdle: Bool

  fileprivate init(_ snapshot: CogTurnChainDiagnosticSnapshot) {
    warningCount = snapshot.warningCount
    lastWarning = snapshot.lastWarning.map(CogTurnChainWarning.init)
    isIdle = snapshot.isIdle
  }
}

extension Cogtext {
  /// The latest long turn chain and whether the context is idle now.
  ///
  /// Tests can inspect the warning without accessing graph storage. The API and
  /// guard compile out of release builds.
  public var turnChainDiagnostic: CogTurnChainDiagnostic {
    CogTurnChainDiagnostic(turnChainDiagnosticSnapshot)
  }
}

#endif
