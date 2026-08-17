#if DEBUG

/// The kind of graph activity recorded by one debug-history entry.
///
/// History exists only in debug builds; its types and recording calls are
/// compiled out of release artifacts. This enum is `nonisolated` and
/// `Sendable`, so a copied event value has no MainActor requirement.
public nonisolated enum CogHistoryEvent: Sendable, Equatable {
  /// One outer graph turn began under its commit or system-generated name.
  case turn

  /// A manual source published a changed staged value at a commit boundary.
  case write

  /// A synchronous derived cog's dependency-selecting selector ran.
  case recompute

  /// One changed UI boundary emitted its coalesced Observation notice.
  case notice

  /// A reaction or watch body ran, including its initial tracking run.
  case effect
}

/// One debug-history entry.
///
/// Entries keep raw labels and keys. ``name`` renders them on demand, so the
/// hot turn path does no string interpolation. An entry describes diagnostic
/// activity, not a replayable state mutation or retained value snapshot.
/// Access follows the owning context's MainActor isolation.
public struct CogHistoryEntry {
  /// Which kind of work this entry records.
  public let event: CogHistoryEvent

  /// The ordinal of the turn this entry belongs to, counting from one.
  ///
  /// Entries produced during a turn share its number. Work outside a turn uses
  /// the latest completed number, or zero before any turn, so this value is an
  /// ordering aid rather than a promise that every event occurred inside a turn.
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
      return "\(label)[\(key.erased.base)]"
    case .effect(let label):
      return "\(label)"
    }
  }

  /// The unrendered identifying material retained until ``name`` is requested.
  internal let subject: CogHistorySubject

  /// Creates one entry from diagnostic material already captured on the hot path.
  ///
  /// Keeping subject rendering out of this initializer lets recording append
  /// labels and keys without interpolating them.
  ///
  /// - Parameters:
  ///   - event: The category of graph activity that occurred.
  ///   - turn: The active or most recently completed turn ordinal.
  ///   - subject: Raw identifying material to render only on display.
  internal init(event: CogHistoryEvent, turn: UInt64, subject: CogHistorySubject) {
    self.event = event
    self.turn = turn
    self.subject = subject
  }
}

/// A bounded snapshot of one context's debug-only diagnostic history.
///
/// Taking a snapshot copies the ring value with copy-on-write storage; later
/// context activity does not change the snapshot. ``entries`` rotates the
/// wrapped storage on demand to expose chronological order. History is for
/// debugging and logging, not application behavior or correctness decisions.
public struct CogHistory {
  /// The most entries this history will ever hold at once.
  public let capacity: Int

  /// How many entries this snapshot captured, never more than ``capacity``.
  public var count: Int { ring.count }

  /// The captured entries in chronological order, oldest first.
  ///
  /// Materializing this array performs the ring rotation only when the buffer
  /// had wrapped.
  public var entries: [CogHistoryEntry] {
    guard oldest != 0 else { return ring }
    return Array(ring[oldest...]) + Array(ring[..<oldest])
  }

  /// The captured ring in its write-optimized storage order.
  private let ring: [CogHistoryEntry]

  /// Where chronological traversal starts after the ring wraps.
  private let oldest: Int

  /// Captures the ring representation without eagerly rotating it.
  ///
  /// The log owns and validates these ring invariants; the public snapshot keeps
  /// the compact layout private and exposes chronological traversal through
  /// ``entries``.
  ///
  /// - Parameters:
  ///   - ring: The copied entries in the log's storage order.
  ///   - oldest: The index of the chronological first entry after wrapping.
  ///   - capacity: The configured upper bound, including when `ring` is sparse.
  internal init(ring: [CogHistoryEntry], oldest: Int, capacity: Int) {
    self.ring = ring
    self.oldest = oldest
    self.capacity = capacity
  }
}

extension Cogs {
  /// This context's recent debug history.
  ///
  /// The returned value is a snapshot: subsequent turns do not mutate it.
  /// Ask again for a newer view. History types, storage, and recording compile
  /// out of release builds, so production code cannot depend on this property.
  public var debugHistory: CogHistory { historyLog.snapshot }
}

#endif
