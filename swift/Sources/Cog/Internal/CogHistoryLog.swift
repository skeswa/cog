#if DEBUG

/// What Cog remembers about recent turns, in a ring that never grows.
///
/// Modeled on ``CogSettleStack``: a context-owned struct with a private array,
/// reused for the life of the context. perf §8 asks for a fixed-size ring of
/// records whose labels are resolved only at display, and this is the
/// class-node core's version of that. When the measured arena lands, the
/// records become integer slots and the recording sites do not change.
internal struct CogHistoryLog {
  /// How many entries the ring holds.
  ///
  /// 256 is a working number, not a measured one — perf §8 fixes the shape of
  /// this log, not its size. It is long enough to hold the burst of turns
  /// behind one user gesture along with the turns that led up to it, and short
  /// enough to stay small in a debug build.
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

  /// Records a staged value that really changed at the commit boundary.
  mutating func recordWrite(label: CogLabel, key: AnyHashable?) {
    record(CogHistoryEntry(event: .write, turn: turn, subject: .cog(label, key)))
  }

  /// Records one run of a derived cog's selector.
  mutating func recordRecompute(label: CogLabel, key: AnyHashable?) {
    record(CogHistoryEntry(event: .recompute, turn: turn, subject: .cog(label, key)))
  }

  /// Appends until the ring is full, then overwrites its oldest slot.
  /// Records one run of a reaction or watch body.
  mutating func recordEffect(label: CogLabel) {
    record(CogHistoryEntry(event: .effect, turn: turn, subject: .effect(label)))
  }

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
/// A turn is named by its caller; a cog and an effect are each named by their
/// own declaration. Keeping all three unrendered is what lets
/// ``CogHistoryEntry/name`` do the string work at display time instead of on
/// the turn path.
internal enum CogHistorySubject {
  case turn(String)
  case cog(CogLabel, AnyHashable?)
  case effect(CogLabel)
}

#endif
