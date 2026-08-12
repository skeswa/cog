#if DEBUG

public import Cog

/// One turn or reaction in a long synchronous causal chain.
public nonisolated enum CogQuiescenceCause: Sendable, Equatable {
  case turn(String)
  case reaction(String)
}

/// One DEBUG warning produced after a context crossed its quiescence guard.
public nonisolated struct CogQuiescenceWarning: Sendable, Equatable {
  public let uninterruptedTurnCount: Int
  public let causalChain: [CogQuiescenceCause]
  public let causalChainIsTruncated: Bool

  fileprivate init(_ snapshot: CogQuiescenceWarningSnapshot) {
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

/// DEBUG-only behavior exposed by the quiescence diagnostic seam.
public nonisolated struct CogQuiescenceDiagnostic: Sendable, Equatable {
  public let warningCount: Int
  public let lastWarning: CogQuiescenceWarning?
  public let isIdle: Bool

  fileprivate init(_ snapshot: CogQuiescenceDiagnosticSnapshot) {
    warningCount = snapshot.warningCount
    lastWarning = snapshot.lastWarning.map(CogQuiescenceWarning.init)
    isIdle = snapshot.isIdle
  }
}

extension Cogtext {
  /// The last long uninterrupted drain this context warned about, and whether
  /// the synchronous graph lane is idle now.
  ///
  /// This is a narrow behavior contract for tests. It exposes no turn phase,
  /// queue, state, edge, or graph representation, and it is absent from release
  /// builds along with the guard it observes.
  public var quiescenceDiagnostic: CogQuiescenceDiagnostic {
    CogQuiescenceDiagnostic(quiescenceDiagnosticSnapshot)
  }
}

#endif
