#if DEBUG

import OSLog

private let cogTurnChainOSLog = OSLog(
  subsystem: "dev.skeswa.cog",
  category: "turn-chain"
)

/// Logs a readable warning for a long turn chain.
///
/// Tests inspect the stored structured snapshot through `CogTesting`; unified
/// log delivery and retention are deliberately not part of graph correctness.
internal func logCogTurnChainWarning(_ warning: CogTurnChainWarningSnapshot) {
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
    Cog warning: A turn chain ran \(warning.uninterruptedTurnCount) turns before returning \
    to idle. The causes were:
      \(chain)\(truncation)
    """
  os_log("%{public}@", log: cogTurnChainOSLog, type: .error, message)
}

#endif
