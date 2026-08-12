#if DEBUG

import OSLog

private let cogQuiescenceOSLog = OSLog(
  subsystem: "dev.skeswa.cog",
  category: "quiescence"
)

/// Emits the human-facing half of the quiescence diagnostic.
///
/// Tests inspect the stored structured snapshot through `CogTesting`; unified
/// log delivery and retention are deliberately not part of graph correctness.
internal func logCogQuiescenceWarning(_ warning: CogQuiescenceWarningSnapshot) {
  let chain = warning.causalChain.map { cause in
    switch cause {
    case .turn(let name):
      return "turn: \(String(reflecting: name))"
    case .reaction(let name):
      return "reaction: \(String(reflecting: name))"
    }
  }.joined(separator: "\n  ")
  let truncation = warning.causalChainIsTruncated ? "\n  … causal chain truncated" : ""
  let message =
    """
    Cog warning: \(warning.uninterruptedTurnCount) turns ran without returning to idle. \
    The causal chain was:
      \(chain)\(truncation)
    """
  os_log("%{public}@", log: cogQuiescenceOSLog, type: .error, message)
}

#endif
