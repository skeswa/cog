#if DEBUG

/// What one debug-history entry says happened.
public nonisolated enum CogHistoryEvent: Sendable, Equatable {
  /// One outer turn began, under the name its `commit` was given.
  case turn

  /// A staged source value changed at the commit boundary.
  case write

  /// A derived cog's selector ran.
  case recompute

  /// A reaction or watch ran.
  case effect
}

/// One debug-history entry.
///
/// Entries keep raw labels and keys. ``name`` renders them on demand, so the
/// turn path does no string work.
public struct CogHistoryEntry {
  /// Which kind of work this entry records.
  public let event: CogHistoryEvent

  /// The ordinal of the turn this entry belongs to, counting from one.
  ///
  /// Work outside a turn uses the latest turn number, or zero before any turn.
  public let turn: UInt64

  /// What Cog calls the subject of this entry.
  ///
  /// Turns use their commit name. Writes and recomputations use the
  /// declaration label and optional key. Effects use the registration label.
  public var name: String {
    switch subject {
    case .turn(let name):
      return name
    case .cog(let label, let key):
      guard let key else { return "\(label)" }
      return "\(label)[\(key.base)]"
    case .effect(let label):
      return "\(label)"
    }
  }

  /// The unrendered identifying material, carried by copy.
  internal let subject: CogHistorySubject

  internal init(event: CogHistoryEvent, turn: UInt64, subject: CogHistorySubject) {
    self.event = event
    self.turn = turn
    self.subject = subject
  }
}

/// A snapshot of one context's debug history, oldest entry first.
///
/// A snapshot shares the ring's storage. ``entries`` rotates it on demand.
public struct CogHistory {
  /// The most entries this history will ever hold at once.
  public let capacity: Int

  /// How many entries it holds right now, never more than ``capacity``.
  public var count: Int { ring.count }

  /// The entries, oldest first.
  public var entries: [CogHistoryEntry] {
    guard oldest != 0 else { return ring }
    return Array(ring[oldest...]) + Array(ring[..<oldest])
  }

  /// The ring in storage order.
  private let ring: [CogHistoryEntry]

  /// Where the oldest entry sits in `ring`, which is zero until it wraps.
  private let oldest: Int

  internal init(ring: [CogHistoryEntry], oldest: Int, capacity: Int) {
    self.ring = ring
    self.oldest = oldest
    self.capacity = capacity
  }
}

extension Cogtext {
  /// This context's recent debug history.
  ///
  /// History types, storage, and recording compile out of release builds.
  public var debugHistory: CogHistory { historyLog.snapshot }
}

#endif
