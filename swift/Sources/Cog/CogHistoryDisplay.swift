#if DEBUG

import OSLog

/// The dedicated unified-log channel for opt-in history display.
private let cogHistoryOSLog = OSLog(subsystem: "dev.skeswa.cog", category: "history")

extension CogHistory {
  /// Writes this bounded snapshot to Apple's unified log, oldest entry first.
  ///
  /// Recording does not log by itself. Names and keys are public log data, so
  /// do not call this when they contain sensitive information. Each call emits
  /// one summary line and then one line per captured entry; it neither clears
  /// the context's ring nor enables future logging.
  ///
  /// History and this display API exist only in debug builds. The method is
  /// synchronous and inherits the snapshot's MainActor isolation.
  public func log() {
    log { line in
      os_log("%{public}@", log: cogHistoryOSLog, type: .debug, line)
    }
  }

  /// Formats the snapshot through an injected line sink.
  ///
  /// Keeping formatting independent from OSLog lets tests prove ordering and
  /// escaping without relying on asynchronous unified-log delivery.
  ///
  /// - Parameter emit: Called synchronously once for the header and once for
  ///   each entry, in display order.
  internal func log(to emit: (String) -> Void) {
    emit("Cog history: \(count) of \(capacity) entries, oldest first")
    for entry in entries {
      emit("[turn \(entry.turn)] \(entry.event.displayName): \(String(reflecting: entry.name))")
    }
  }
}

extension CogHistoryEvent {
  /// Stable lowercase spelling used only by the human-readable display.
  fileprivate var displayName: StaticString {
    switch self {
    case .turn:
      return "turn"
    case .write:
      return "write"
    case .recompute:
      return "recompute"
    case .notice:
      return "notice"
    case .effect:
      return "effect"
    }
  }
}

#endif
