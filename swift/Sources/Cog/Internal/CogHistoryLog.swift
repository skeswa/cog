#if DEBUG

/// What Cog remembers about recent turns, in a ring that never grows.
///
/// The context owns and reuses this fixed-size ring. Labels render only for
/// display (perf §8). The arena core will replace records with integer slots
/// without changing call sites.
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
  mutating func recordWrite(label: CogLabel, key: AnyHashable?) {
    record(CogHistoryEntry(event: .write, turn: turn, subject: .cog(label, key)))
  }

  /// Records one run of a derived cog's selector.
  mutating func recordRecompute(label: CogLabel, key: AnyHashable?) {
    record(CogHistoryEntry(event: .recompute, turn: turn, subject: .cog(label, key)))
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
/// ``CogHistoryEntry/name`` renders these values at display time.
internal enum CogHistorySubject {
  case turn(String)
  case cog(CogLabel, AnyHashable?)
  case effect(CogLabel)
}

#endif
