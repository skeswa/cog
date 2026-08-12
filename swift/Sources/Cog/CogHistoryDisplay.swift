#if DEBUG

import OSLog

private let cogHistoryOSLog = OSLog(subsystem: "dev.skeswa.cog", category: "history")

extension CogHistory {
  /// Writes this bounded snapshot to Apple's unified log, oldest entry first.
  ///
  /// Recording does not log by itself. Names and keys are public log data, so
  /// do not call this when they contain sensitive information.
  public func log() {
    log { line in
      os_log("%{public}@", log: cogHistoryOSLog, type: .debug, line)
    }
  }

  /// The synchronous formatting seam used by the display smoke test.
  ///
  /// Tests use this to verify formatting without relying on unified-log
  /// delivery.
  internal func log(to emit: (String) -> Void) {
    emit("Cog history: \(count) of \(capacity) entries, oldest first")
    for entry in entries {
      emit("[turn \(entry.turn)] \(entry.event.displayName): \(String(reflecting: entry.name))")
    }
  }
}

extension CogHistoryEvent {
  fileprivate var displayName: StaticString {
    switch self {
    case .turn:
      return "turn"
    case .write:
      return "write"
    case .recompute:
      return "recompute"
    case .effect:
      return "effect"
    }
  }
}

#endif
