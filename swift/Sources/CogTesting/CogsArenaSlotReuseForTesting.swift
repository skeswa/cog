public import Cog

/// Identity-free evidence that an arena row was safely reused.
///
/// This diagnostic exists only in an arena-selected `CogTesting` build. It
/// exposes scalar facts needed by PERF-05 without turning an arena slot into a
/// public Cog value reference or allowing application code to retain one.
public nonisolated struct ArenaSlotReuse: Equatable, Sendable {
  /// Integer row formerly occupied by the released state.
  public let releasedIndex: Int32

  /// Generation belonging to the released state's retired lifetime.
  public let releasedGeneration: UInt16

  /// Integer row occupied by the replacement state.
  public let replacementIndex: Int32

  /// Generation belonging to the replacement's live lifetime.
  public let replacementGeneration: UInt16

  /// Whether the allocator reused the same compact integer row.
  public var reusedIndex: Bool { releasedIndex == replacementIndex }

  /// Whether reuse assigned a distinct lifetime to that row.
  public var changedGeneration: Bool { releasedGeneration != replacementGeneration }
}

extension Cogs {
  /// Releases one automatic state, creates another, and reports allocator facts.
  ///
  /// Both declarations run through normal arena settlement. The first must be
  /// unobserved and have no subscribers, matching a lifetime-eligible automatic
  /// row; the replacement is settled before the result returns.
  public func probeArenaSlotReuse<ReleasedValue, ReplacementValue>(
    releasing releasedReference: Cog<ReleasedValue>,
    replacingWith replacementReference: Cog<ReplacementValue>
  ) -> ArenaSlotReuse {
    let snapshot = arenaSlotReuseForTesting(
      releasing: releasedReference,
      replacingWith: replacementReference
    )
    return ArenaSlotReuse(
      releasedIndex: snapshot.releasedIndex,
      releasedGeneration: snapshot.releasedGeneration,
      replacementIndex: snapshot.replacementIndex,
      replacementGeneration: snapshot.replacementGeneration
    )
  }

  /// Deliberately reaches a retired token after its row is reused.
  ///
  /// Call only from a debug exit test. The expected result is Cog's stale-slot
  /// fatal error; returning normally means generation validation failed.
  public func trapOnStaleArenaSlotAccess<ReleasedValue, ReplacementValue>(
    releasing releasedReference: Cog<ReleasedValue>,
    replacingWith replacementReference: Cog<ReplacementValue>
  ) {
    trapOnStaleArenaSlotAccessForTesting(
      releasing: releasedReference,
      replacingWith: replacementReference
    )
  }
}
