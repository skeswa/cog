#if DEBUG

/// What one debug-history entry says happened.
///
/// Spelled `nonisolated` for the same reason ``CogVersion`` is: the module
/// compiles with `.defaultIsolation(MainActor.self)`, and an event tag is
/// inert data even though the context that records it is not.
public nonisolated enum CogHistoryEvent: Sendable, Equatable {
  /// One outer turn began, under the name its `commit` was given.
  case turn

  /// A staged source value crossed the commit boundary and really changed.
  case write

  /// A derived cog's selector ran.
  case recompute
}

/// One thing Cog did, as the debug history remembers it.
///
/// An entry keeps what the recording site already had — a turn's name, or a
/// declaration's ``CogLabel`` and key — and renders a `String` only when
/// something asks for ``name``. That ordering is the point (perf §8):
/// recording sits on the turn path and must not do string work, while display
/// happens approximately never.
public struct CogHistoryEntry {
  /// Which kind of work this entry records.
  public let event: CogHistoryEvent

  /// The ordinal of the turn this entry belongs to, counting from one.
  ///
  /// Work done outside a turn — the lazy first computation behind a read —
  /// carries the ordinal of the most recently started turn, or zero when no
  /// turn has run yet. This is deliberately not ``CogVersion``: the graph
  /// revision happens to advance once per turn today, and nothing about
  /// history should depend on that staying true.
  public let turn: UInt64

  /// What Cog calls the subject of this entry.
  ///
  /// For a turn, the name its `commit` was given, which by default is the op
  /// method that called it. For a write or a recomputation, the declaration's
  /// label, subscripted by key when the declaration is keyed. Rendered here,
  /// at display time, never at record time.
  public var name: String {
    switch subject {
    case .turn(let name):
      return name
    case .cog(let label, let key):
      guard let key else { return "\(label)" }
      return "\(label)[\(key.base)]"
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
/// Taking a snapshot is cheap: it shares the ring's storage and rotates it
/// only when ``entries`` is actually asked for, so a loop that watches
/// ``count`` across many turns does not rebuild the ring on every turn.
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

  /// The ring exactly as the log holds it, which is only sorted once it wraps.
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
  /// What this context has done lately, for a person trying to understand it.
  ///
  /// Debug builds only. A release build has no history to read and paid
  /// nothing to record one (`HIST-04`), which is why this whole file — the
  /// record types, this accessor, and every call site behind it — compiles
  /// out rather than becoming an empty log.
  public var debugHistory: CogHistory { historyLog.snapshot }
}

#endif
