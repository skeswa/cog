#if DEBUG

/// Core-neutral DEBUG recording entry points.
///
/// Keeping dispatch at these cold capability boundaries lets class-backed
/// paths continue working while arena graph walks record their slot identity
/// directly. Every method and call site compiles out together in release.
extension Cogs {
  /// Records one outer turn before its body runs.
  func recordHistoryTurn(named name: String) {
    #if COG_CORE_ARENA
    arenaCore.recordHistoryTurn(named: name)
    #else
    historyLog.recordTurn(named: name)
    #endif
  }

  /// Records a changed class-backed source during incremental migration.
  func recordHistoryWrite(label: CogLabel, key: CogKey?) {
    #if COG_CORE_ARENA
    arenaCore.recordHistoryState(event: .write, label: label, key: key)
    #else
    historyLog.recordWrite(label: label, key: key)
    #endif
  }

  /// Records a class-backed selector run during incremental migration.
  func recordHistoryRecompute(label: CogLabel, key: CogKey?) {
    #if COG_CORE_ARENA
    arenaCore.recordHistoryState(event: .recompute, label: label, key: key)
    #else
    historyLog.recordRecompute(label: label, key: key)
    #endif
  }

  /// Records a class-backed Observation notice during incremental migration.
  func recordHistoryNotice(label: CogLabel, key: CogKey?) {
    #if COG_CORE_ARENA
    arenaCore.recordHistoryState(event: .notice, label: label, key: key)
    #else
    historyLog.recordNotice(label: label, key: key)
    #endif
  }

  /// Records one reaction or watch run in the active core's total event order.
  func recordHistoryEffect(label: CogLabel) {
    #if COG_CORE_ARENA
    arenaCore.recordHistoryEffect(label: label)
    #else
    historyLog.recordEffect(label: label)
    #endif
  }

  /// Materializes this context's current core-specific history snapshot.
  var historySnapshot: CogHistory {
    #if COG_CORE_ARENA
    arenaCore.historySnapshot
    #else
    historyLog.snapshot
    #endif
  }
}

#endif
