/// One exact lifetime of a scalar row in ``CogArenaStorage``.
///
/// The index selects parallel structure-of-arrays columns. The generation
/// distinguishes a row's current occupant from an earlier state that used the
/// same index. This token is internal graph machinery, never value-reference
/// identity: public value references remain stable descriptor-and-key names.
internal nonisolated struct CogArenaSlot: Hashable {
  /// The dense position shared by every scalar column.
  let index: Int32

  /// The occupant generation that must still match the arena's row.
  let generation: UInt16
}

/// Compact graph and allocator state for one arena row.
///
/// A live clean row carries only `occupied`. `check` and `dirty` are the
/// settlement strength bits the arena core will drive; they must not coexist
/// once propagation owns the column. `computing` is orthogonal and marks the
/// active pull path. An empty value belongs only to a released row.
internal nonisolated struct CogArenaStateFlags: OptionSet, Sendable {
  /// The packed byte stored in the arena's `flags` column.
  let rawValue: UInt8

  /// The row currently belongs to a live state.
  static let occupied = CogArenaStateFlags(rawValue: 1 << 0)

  /// A producer may have changed, so versions must be checked before rerunning.
  static let check = CogArenaStateFlags(rawValue: 1 << 1)

  /// A direct input changed, so the state must recompute.
  static let dirty = CogArenaStateFlags(rawValue: 1 << 2)

  /// The state is on the active synchronous computation path.
  static let computing = CogArenaStateFlags(rawValue: 1 << 3)

  /// The accumulating turn has staged this source once.
  static let touched = CogArenaStateFlags(rawValue: 1 << 4)
}

/// Context-owned scalar storage for the data-oriented core.
///
/// Every array is indexed by the same ``CogArenaSlot/index``. Allocation grows
/// the columns in lockstep; release clears the complete scalar row, advances
/// its generation, and makes the index available for LIFO reuse. Typed values
/// and edges deliberately live elsewhere: sibling M6 storage owns their
/// measured representations without changing this row-ownership contract.
@MainActor
internal final class CogArenaStorage {
  /// Sentinel for no Observation boundary.
  static let noIndex: Int32 = -1

  /// Packed liveness, settlement, and computation marks by slot.
  var flags: ContiguousArray<CogArenaStateFlags> = []

  /// Last revision in which each row's value changed.
  var changedAt: ContiguousArray<UInt32> = []

  /// Last revision through which each row was proved current.
  var checkedAt: ContiguousArray<UInt32> = []

  /// Head of each row's dependency list.
  var deps: ContiguousArray<CogEdgeIndex> = []

  /// Head of each row's subscriber list.
  var subs: ContiguousArray<CogEdgeIndex> = []

  /// Context-local descriptor dispatch index for each occupied row.
  var descriptor: ContiguousArray<Int32> = []

  /// Observation-boundary index per row, or ``noIndex`` until a UI read.
  var boundary: ContiguousArray<Int32> = []

  /// Occupant generation per row, advanced before an index may be reused.
  var generation: ContiguousArray<UInt16> = []

  /// Released indices whose generation can still advance, in reuse order.
  ///
  /// LIFO reuse keeps recently touched scalar rows hot and makes allocation a
  /// single pop. A row at `UInt16.max` is retired instead of entering this list
  /// so generation wraparound can never make an old token current again.
  private var reusableSlots: ContiguousArray<Int32> = []

  /// Number of rows whose `occupied` bit is set.
  private(set) var liveCount = 0

  /// Number of scalar rows retained by the arena, including reusable and
  /// generation-exhausted rows.
  var rowCount: Int { flags.count }

  /// Allocates one live scalar row and returns its exact occupant token.
  ///
  /// Reuse never changes the array lengths. A fresh row appends one default to
  /// every column before it becomes observable through the returned token.
  func allocate() -> CogArenaSlot {
    if let reusable = reusableSlots.popLast() {
      let index = Int(reusable)
      resetScalars(at: index, occupied: true)
      liveCount += 1
      return CogArenaSlot(index: reusable, generation: generation[index])
    }

    guard flags.count <= Int(Int32.max) else {
      fatalError("Cog exhausted its Int32 arena slot space.")
    }

    let slot = Int32(flags.count)
    flags.append(.occupied)
    changedAt.append(0)
    checkedAt.append(0)
    deps.append(.none)
    subs.append(.none)
    descriptor.append(Self.noIndex)
    boundary.append(Self.noIndex)
    generation.append(0)
    liveCount += 1
    return CogArenaSlot(index: slot, generation: 0)
  }

  /// Releases the exact current occupant of a row.
  ///
  /// Every scalar is cleared before the index enters the free list. Generation
  /// exhaustion retires the row: reusing it with a wrapped generation would
  /// make a sufficiently old token valid again, which is worse than retaining
  /// one cold scalar row.
  func release(_ slot: CogArenaSlot) {
    let index = index(of: slot)
    resetScalars(at: index, occupied: false)
    liveCount -= 1

    guard generation[index] < UInt16.max else { return }
    generation[index] += 1
    reusableSlots.append(slot.index)
  }

  /// Whether `slot` still names the live occupant at its index.
  ///
  /// This is the non-trapping check used at generation boundaries. A released,
  /// reused, out-of-range, or otherwise stale token returns `false`.
  func contains(_ slot: CogArenaSlot) -> Bool {
    guard slot.index >= 0 else { return false }
    let index = Int(slot.index)
    guard index < flags.count else { return false }
    return flags[index].contains(.occupied) && generation[index] == slot.generation
  }

  /// Resolves a current token to the native array index.
  ///
  /// Centralizing this validation keeps stale access from silently reaching a
  /// new occupant. Hot graph walks can later replace repeated validation with
  /// one checked entry boundary if measurements require it.
  func index(of slot: CogArenaSlot) -> Int {
    guard contains(slot) else {
      fatalError(
        "Cog tried to use stale arena slot \(slot.index) at generation \(slot.generation)."
      )
    }
    return Int(slot.index)
  }

  /// Restores every non-generation scalar to its unlinked initial value.
  ///
  /// Generation advances separately during release and must survive this
  /// reset so the next occupant receives a distinct token.
  private func resetScalars(at index: Int, occupied: Bool) {
    flags[index] = occupied ? .occupied : []
    changedAt[index] = 0
    checkedAt[index] = 0
    deps[index] = .none
    subs[index] = .none
    descriptor[index] = Self.noIndex
    boundary[index] = Self.noIndex
  }
}
