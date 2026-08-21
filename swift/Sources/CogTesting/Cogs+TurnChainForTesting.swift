#if DEBUG

public import Cog

// MARK: - Turn-chain inspection

/// One turn or reaction in a long synchronous causal chain.
public nonisolated enum CogTurnChainCause: Sendable, Equatable {
  /// A named graph turn in the order it entered the uninterrupted chain.
  case turn(String)

  /// A named reaction run caused by the preceding completed turn.
  case reaction(String)
}

/// One DEBUG warning produced when synchronous write-back exceeds the threshold.
///
/// This immutable copy exposes causal names and truncation without exposing the
/// runtime tracker's bounded storage.
public nonisolated struct CogTurnChainWarning: Sendable, Equatable {
  /// The turns completed when this warning crossed its threshold.
  public let uninterruptedTurnCount: Int

  /// The retained causal prefix in the order the work occurred.
  public let causalChain: [CogTurnChainCause]

  /// Whether the bounded causal prefix omitted later causes.
  public let causalChainIsTruncated: Bool

  /// Copies a runtime snapshot into the testing product's stable value types.
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

/// Current DEBUG-only turn-chain state exposed without graph internals.
public nonisolated struct CogTurnChainDiagnostic: Sendable, Equatable {
  /// How many threshold warnings this context has emitted.
  public let warningCount: Int

  /// The most recent warning, or `nil` before the first long chain.
  public let lastWarning: CogTurnChainWarning?

  /// Whether no turn, reaction, settlement, or queued write-back remains active.
  public let isIdle: Bool

  /// Copies the context's internal diagnostic snapshot for a public assertion.
  fileprivate init(_ snapshot: CogTurnChainDiagnosticSnapshot) {
    warningCount = snapshot.warningCount
    lastWarning = snapshot.lastWarning.map(CogTurnChainWarning.init)
    isIdle = snapshot.isIdle
  }
}

extension Cogs {
  /// The accumulated long-chain warnings and current quiescence of this context.
  ///
  /// Tests can inspect the warning without accessing graph storage. The API and
  /// guard compile out of release builds.
  public var turnChainDiagnostic: CogTurnChainDiagnostic {
    CogTurnChainDiagnostic(turnChainDiagnosticSnapshot)
  }
}

#endif
