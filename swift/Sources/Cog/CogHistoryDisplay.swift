#if DEBUG

import OSLog

private let cogHistoryOSLog = OSLog(subsystem: "dev.skeswa.cog", category: "history")

extension CogHistory {
  /// Writes this bounded snapshot to Apple's unified log, oldest entry first.
  ///
  /// Display is explicit: recording history never logs by itself. Names and
  /// keyed identities are emitted as public debug-log data so the result is
  /// useful in Console. Do not call this method when those identifiers are
  /// sensitive.
  public func log() {
    log { line in
      os_log("%{public}@", log: cogHistoryOSLog, type: .debug, line)
    }
  }

  /// The synchronous formatting seam used by the display smoke test.
  ///
  /// Keeping it beside the real emitter proves formatting without making
  /// unified-log persistence, delivery timing, or Console part of graph
  /// correctness.
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
