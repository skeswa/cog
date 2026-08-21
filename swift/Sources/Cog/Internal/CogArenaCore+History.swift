#if COG_CORE_ARENA

// MARK: - History

/// Debug-only history recording and materialization for the arena core.
///
/// Events stay integer-backed until a snapshot asks this extension to resolve
/// descriptor labels. The complete extension compiles out of release builds.
extension CogArenaCore {
  #if DEBUG
  /// Records one outer turn in the arena-owned total history order.
  func recordHistoryTurn(named name: String) {
    historyLog.recordTurn(named: name)
  }

  /// Records a class-backed state event while its capability is still bridged.
  func recordHistoryState(event: CogHistoryEvent, label: CogLabel, key: CogKey?) {
    historyLog.recordState(event: event, label: label, key: key)
  }

  /// Records one export offer beside arena graph events.
  func recordHistoryOffer(label: CogLabel) {
    historyLog.recordOffer(label: label)
  }

  /// Records one reaction or watch body beside arena graph events.
  func recordHistoryEffect(label: CogLabel) {
    historyLog.recordEffect(label: label)
  }

  /// Public debug snapshot with descriptor labels resolved off the hot path.
  var historySnapshot: CogHistory {
    historyLog.snapshot { descriptorIndex in
      descriptorRecord(at: descriptorIndex).label
    }
  }

  /// Records an arena row as integer descriptor identity plus its erased key.
  func recordHistoryState(event: CogHistoryEvent, slot: CogArenaSlot) {
    let row = arena.index(of: slot)
    let record = descriptorRecord(forRow: row)
    historyLog.recordState(
      event: event,
      descriptor: record.index,
      key: record.key(at: row)
    )
  }
  #endif
}
#endif
