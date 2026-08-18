#if DEBUG

/// What Cog remembers about recent turns, in a ring that never grows.
///
/// The simple core's context owns and reuses this fixed-size ring. Labels render
/// only for display (perf §8); the arena core uses ``CogArenaHistoryLog``'s
/// integer records behind the same recording facade. MainActor confinement
/// gives event insertion a total order: each outer turn is recorded before its
/// body, and graph work it causes then appears in actual flush order. Lazy reads
/// and initial reaction runs outside a turn attach to the latest ordinal (or
/// zero before the first turn) without inventing a turn. The entire recorder is
/// excluded from release builds.
internal struct CogHistoryLog {
  /// How many entries the ring holds.
  ///
  /// 256 is a working value. Benchmarks will choose the final size (perf §8).
  static let capacity = 256

  /// Filled to `capacity`, then written in place, oldest slot first.
  private var ring: [CogHistoryEntry] = []

  /// Where the next entry goes once the ring is full, which is also where the
  /// oldest entry sits while it is full.
  private var next = 0

  /// The turn ordinal stamped onto entries, advanced by each outer turn.
  private var turn: UInt64 = 0

  /// The history as a reader sees it.
  ///
  /// `CogHistory` receives ring storage plus its logical oldest index, so taking
  /// a snapshot does not rotate or mutate the context's next-overwrite cursor.
  var snapshot: CogHistory {
    CogHistory(
      ring: ring,
      oldest: ring.count == Self.capacity ? next : 0,
      capacity: Self.capacity
    )
  }

  /// Records one outer turn beginning, and makes it the turn later entries
  /// belong to.
  mutating func recordTurn(named name: String) {
    // Unlike `CogVersion.advanced()`, a wrapped history ordinal cannot make an
    // old value look current, so this counter needs no exhaustion trap: at one
    // turn per nanosecond a `UInt64` lasts about five centuries.
    turn &+= 1
    record(CogHistoryEntry(event: .turn, turn: turn, subject: .turn(name)))
  }

  /// Records a staged value that changed at the commit boundary.
  mutating func recordWrite(label: CogLabel, key: CogKey?) {
    record(CogHistoryEntry(event: .write, turn: turn, subject: .cog(label, key)))
  }

  /// Records one run of a derived cog's selector.
  mutating func recordRecompute(label: CogLabel, key: CogKey?) {
    record(CogHistoryEntry(event: .recompute, turn: turn, subject: .cog(label, key)))
  }

  /// Records one changed UI boundary notice.
  mutating func recordNotice(label: CogLabel, key: CogKey?) {
    record(CogHistoryEntry(event: .notice, turn: turn, subject: .cog(label, key)))
  }

  /// Records one changed or initial export offer.
  mutating func recordOffer(label: CogLabel) {
    record(CogHistoryEntry(event: .offer, turn: turn, subject: .offer(label)))
  }

  /// Records one run of a reaction or watch body.
  mutating func recordEffect(label: CogLabel) {
    record(CogHistoryEntry(event: .effect, turn: turn, subject: .effect(label)))
  }

  /// Appends until the ring is full, then overwrites its oldest slot.
  private mutating func record(_ entry: CogHistoryEntry) {
    guard ring.count == Self.capacity else {
      ring.reserveCapacity(Self.capacity)
      ring.append(entry)
      return
    }

    ring[next] = entry
    next = (next + 1) % Self.capacity
  }
}

/// The unrendered identity behind one history entry.
///
/// ``CogHistoryEntry/name`` renders these values at display time. Subjects keep
/// declaration labels and erased keys, not state or descriptor references, so
/// retaining debug history cannot extend graph-state lifetime.
internal enum CogHistorySubject {
  /// A named outer turn, recorded before its staging body begins.
  case turn(String)
  /// One descriptor label and optional key involved in graph propagation.
  case cog(CogLabel, CogKey?)
  /// One export registration whose body offered a value.
  case offer(CogLabel)
  /// One reaction or watch label whose body ran.
  case effect(CogLabel)
}

#endif
