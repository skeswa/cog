#if DEBUG

/// One compact event in the arena core's fixed-capacity debug ring.
///
/// The subject is an integer into the parallel bounded subject ring. Arena
/// state subjects in that sidecar retain only a descriptor index and erased
/// key; no state, slot token, or descriptor reference enters the hot record.
private nonisolated struct CogArenaHistoryRecord: Sendable {
  /// Category of graph activity that occurred.
  let event: CogHistoryEvent

  /// Current outer-turn ordinal, or the latest ordinal for work outside a turn.
  let turn: UInt64

  /// Index of this record's raw subject in the parallel fixed-capacity ring.
  let subject: Int32
}

/// Raw diagnostic identity retained beside one arena history record.
///
/// Arena graph work records the integer descriptor dispatch index and key. Turn
/// and hybrid terminal paths retain their already-existing names or labels; these
/// cold values are bounded by the same ring and never enter release builds.
private enum CogArenaHistorySubject {
  /// Name supplied by one outer application or system turn.
  case turn(String)

  /// Integer descriptor dispatch identity plus the exact keyed row identity.
  case arenaCog(descriptor: Int32, key: CogKey?)

  /// Export label retained while offers use their class terminal bridge.
  case offer(CogLabel)

  /// Reaction or watch label retained while effects use their class bridge.
  case effect(CogLabel)
}

/// DEBUG-only integer recorder for one arena context.
///
/// Records and subjects grow together to 256 entries, then overwrite the same
/// positions in place. Arena events append integer descriptor indices on the
/// hot path. A public snapshot resolves those indices through the context's
/// descriptor registry and converts the ring to ordinary ``CogHistoryEntry``
/// values only when a debugger or test asks to display it.
@MainActor
internal struct CogArenaHistoryLog {
  /// Bounded history capacity shared by every arena configuration.
  static let capacity = 256

  /// Compact records in physical ring order.
  private var records: ContiguousArray<CogArenaHistoryRecord> = []

  /// Raw subjects parallel to `records` and overwritten at the same index.
  private var subjects: ContiguousArray<CogArenaHistorySubject> = []

  /// Next physical overwrite position once both rings are full.
  private var next = 0

  /// Turn ordinal stamped onto later state, offer, and effect records.
  private var turn: UInt64 = 0

  /// Records one outer turn before its staging body begins.
  mutating func recordTurn(named name: String) {
    turn &+= 1
    record(event: .turn, subject: .turn(name))
  }

  /// Records one arena state event using descriptor dispatch identity.
  mutating func recordState(
    event: CogHistoryEvent,
    descriptor: Int32,
    key: CogKey?
  ) {
    record(event: event, subject: .arenaCog(descriptor: descriptor, key: key))
  }

  /// Records one export offer in the shared arena event order.
  mutating func recordOffer(label: CogLabel) {
    record(event: .offer, subject: .offer(label))
  }

  /// Records one reaction or watch run in the shared arena event order.
  mutating func recordEffect(label: CogLabel) {
    record(event: .effect, subject: .effect(label))
  }

  /// Materializes a public snapshot, resolving arena descriptor labels now.
  ///
  /// The resolver is deliberately a snapshot concern. Recording a changed row
  /// never loads or formats its descriptor label.
  func snapshot(resolveDescriptor: (Int32) -> CogLabel) -> CogHistory {
    let entries = records.map { record in
      let subject = subjects[Int(record.subject)]
      let renderedSubject: CogHistorySubject =
        switch subject {
        case .turn(let name):
          .turn(name)
        case .arenaCog(let descriptor, let key):
          .cog(resolveDescriptor(descriptor), key)
        case .offer(let label):
          .offer(label)
        case .effect(let label):
          .effect(label)
        }
      return CogHistoryEntry(
        event: record.event,
        turn: record.turn,
        subject: renderedSubject
      )
    }
    return CogHistory(
      ring: Array(entries),
      oldest: records.count == Self.capacity ? next : 0,
      capacity: Self.capacity
    )
  }

  /// Appends one record and subject, or overwrites their oldest shared slot.
  private mutating func record(event: CogHistoryEvent, subject: CogArenaHistorySubject) {
    let index: Int
    if records.count < Self.capacity {
      records.reserveCapacity(Self.capacity)
      subjects.reserveCapacity(Self.capacity)
      index = records.count
      subjects.append(subject)
      records.append(
        CogArenaHistoryRecord(event: event, turn: turn, subject: Int32(index))
      )
      return
    }

    index = next
    subjects[index] = subject
    records[index] = CogArenaHistoryRecord(event: event, turn: turn, subject: Int32(index))
    next = (next + 1) % Self.capacity
  }
}

#endif
