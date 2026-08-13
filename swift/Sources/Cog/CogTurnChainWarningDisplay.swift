#if DEBUG

import OSLog

/// The dedicated channel for debug-only runaway turn-chain diagnostics.
private let cogTurnChainOSLog = OSLog(
  subsystem: "dev.skeswa.cog",
  category: "turn-chain"
)

/// Renders and logs one long uninterrupted turn-chain warning.
///
/// The tracker records raw causes on the hot path; this boundary performs the
/// string work only after the debug threshold is exceeded. Names are logged as
/// public data so the diagnostic remains readable in Console. Tests inspect the
/// stored snapshot through `CogTesting` instead of relying on unified-log
/// delivery, and all of this code compiles out of release builds.
///
/// - Parameter warning: The bounded causal-chain snapshot and uninterrupted
///   turn count captured by the tracker.
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
