/// Primitive result of the package-only arena slot-reuse probe.
///
/// `CogTesting` maps this internal representation to its public diagnostic
/// value. Production API never exposes arena indices or generations, so a
/// normal value reference remains a stable descriptor-and-key name.
package nonisolated struct CogArenaSlotReuseSnapshot: Sendable {
  /// Row returned to the allocator by the released automatic state.
  package let releasedIndex: Int32

  /// Generation carried by the released state's now-stale token.
  package let releasedGeneration: UInt16

  /// Row allocated to the replacement automatic state.
  package let replacementIndex: Int32

  /// Generation carried by the replacement's live token.
  package let replacementGeneration: UInt16
}

/// Production role of one descriptor in the arena vertical slice.
#if !COG_ARENA_COMPACT
@usableFromInline
#endif
internal nonisolated enum CogArenaDescriptorKind: Equatable {
  /// A source whose typed column owns current and pending values.
  case manual

  /// A synchronous selector whose typed column begins without a value.
  case automatic

  /// An asynchronous selector whose typed status column begins without a value.
  case async
}

/// Type-erased setup record retained once per descriptor by an arena context.
///
/// Normal typed access downcasts `column` at the descriptor boundary. Indexed
/// graph walks instead use the scalar descriptor index on each row and invoke
/// one descriptor-level function, never a per-state closure or existential.
@MainActor
#if !COG_ARENA_COMPACT
@usableFromInline
#endif
internal final class CogArenaDescriptorRecord {
  // Written out, and `nonisolated`, per the rule at the top of
  // `CogDescriptor.swift`. A synthesized `deinit` on a main-actor-isolated
  // class is main-actor-isolated too, so every deallocation asks the
  // concurrency runtime which executor it is on (`M9-13`).
  nonisolated deinit {}

  /// Process identity of the public declaration represented by this record.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  let identity: ObjectIdentifier

  /// Human-readable declaration label used only when rendering diagnostics.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  let label: CogLabel

  /// Dense context-local dispatch index stored on every row of this descriptor.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  let index: Int32

  /// Whether rows are manual, synchronous automatic, or asynchronous values.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  let kind: CogArenaDescriptorKind

  /// Retention policy shared by every row belonging to this descriptor.
  ///
  /// Keeping it on the descriptor dispatch record avoids repeating an enum in
  /// every scalar row. Only the cold lease and release paths load it.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  let lifetime: CogStateLifetime

  /// Concrete ``CogArenaValueColumn`` restored by checked generic setup.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  let column: AnyObject

  /// Descriptor-local async task sidecars, or `nil` for synchronous values.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  let asyncColumn: AnyObject?

  /// Publishes a pending source value, or `nil` for automatic descriptors.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  let publishSource: (@MainActor (CogArenaSlot, UInt32, CogArenaDirtyPropagation) -> Bool)?

  /// Reruns one automatic row, or `nil` for manual descriptors.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  let recompute: (@MainActor (CogArenaCore, Cogs, CogArenaSlot, CogKey?) -> Void)?

  /// Sends the field-appropriate mutation through one installed UI boundary.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  let notifyObservation: @MainActor (CogArenaSlot, CogObservationBoundary) -> Void

  /// Clears this descriptor's typed value cell before a scalar row is reused.
  ///
  /// Lifetime expiry starts from an erased slot, so release dispatches once at
  /// the descriptor boundary instead of storing a closure or existential on
  /// every arena row.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  let removeValue: @MainActor (CogArenaSlot) -> Void

  /// Cancels descriptor-owned cold work before the context releases its arena.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  let prepareForContextTeardown: @MainActor () -> Void

  /// Drops the declaration's memoized keyless location for one context.
  ///
  /// Release and teardown reach a descriptor only through its erased record,
  /// so the typed memo is evicted by dispatching once here rather than by
  /// storing a second closure on every arena row. The argument is the calling
  /// context's identity: a descriptor shared with another live context must
  /// keep that context's memo.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  let forgetMemoizedLocation: @MainActor (UInt64) -> Void

  /// Erased selector key by global arena row.
  ///
  /// The current vertical slice exercises keyless rows. Keeping keys on the
  /// descriptor record already avoids a graph-wide key table; later keyed
  /// integration can specialize this storage without changing row dispatch.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  var keys: ContiguousArray<CogKey?> = []

  /// Creates one immutable descriptor dispatch record.
  init(
    identity: ObjectIdentifier,
    label: CogLabel,
    index: Int32,
    kind: CogArenaDescriptorKind,
    lifetime: CogStateLifetime,
    column: AnyObject,
    asyncColumn: AnyObject?,
    publishSource: (@MainActor (CogArenaSlot, UInt32, CogArenaDirtyPropagation) -> Bool)?,
    recompute: (@MainActor (CogArenaCore, Cogs, CogArenaSlot, CogKey?) -> Void)?,
    notifyObservation: @escaping @MainActor (CogArenaSlot, CogObservationBoundary) -> Void,
    removeValue: @escaping @MainActor (CogArenaSlot) -> Void,
    prepareForContextTeardown: @escaping @MainActor () -> Void,
    forgetMemoizedLocation: @escaping @MainActor (UInt64) -> Void
  ) {
    self.identity = identity
    self.label = label
    self.index = index
    self.kind = kind
    self.lifetime = lifetime
    self.column = column
    self.asyncColumn = asyncColumn
    self.publishSource = publishSource
    self.recompute = recompute
    self.notifyObservation = notifyObservation
    self.removeValue = removeValue
    self.prepareForContextTeardown = prepareForContextTeardown
    self.forgetMemoizedLocation = forgetMemoizedLocation
  }

  /// Installs the selector key for one newly allocated row.
  func install(key: CogKey?, at row: Int) {
    if row >= keys.count {
      keys.append(contentsOf: repeatElement(.none, count: row + 1 - keys.count))
    }
    keys[row] = key
  }

  /// Returns the key belonging to one row dispatched through this record.
  func key(at row: Int) -> CogKey? {
    guard row < keys.count else {
      fatalError("Cog found an arena descriptor row without key storage.")
    }
    return keys[row]
  }

  /// Releases the erased key retained for a departing row.
  ///
  /// The descriptor record itself remains registered for the context, but a
  /// removed keyed value must not stay alive merely because its scalar row may
  /// later be occupied by another descriptor.
  func removeKey(at row: Int) {
    guard row < keys.count else {
      fatalError("Cog tried to remove an arena descriptor row without key storage.")
    }
    keys[row] = nil
  }
}

/// Phase of one scalar frame in the iterative pull walk.
internal nonisolated enum CogArenaPullPhase {
  /// Schedule stale dependencies before the consumer.
  case enter

  /// Decide whether the now-current dependencies require a selector run.
  case exit
}

/// One row-only frame retained in the context pull buffer.
internal nonisolated struct CogArenaPullFrame {
  /// Arena row to settle.
  let row: Int32

  /// Whether this frame enters or exits the row.
  let phase: CogArenaPullPhase
}

/// Cursor state for one selector currently capturing dependency reads.
internal nonisolated struct CogArenaDependencyCapture {
  /// Automatic row receiving every read in this scope.
  let consumer: CogArenaSlot

  /// Next prior dependency available for static-prefix reuse.
  var cursor: CogEdgeIndex

  /// Last dependency accepted in selector read order.
  var previous: CogEdgeIndex
}

/// One lazily created Observation boundary pinned to an exact slot lifetime.
///
/// The scalar arena row stores this entry's index. Keeping the boundary object
/// and generation-bearing slot together lets the cold UI flush validate that
/// a permanent boundary was never detached from its original state.
internal nonisolated struct CogArenaObservationEntry {
  /// State lifetime whose UI reads and changes this boundary represents.
  let slot: CogArenaSlot

  /// Registrar-backed object exposed only through phantom Observation reads.
  let boundary: CogObservationBoundary
}

/// Cold grace-period ownership for one arena row.
///
/// The exact arena slot generation rejects a sleeper from a former occupant;
/// this independent generation rejects a cancelled or renewed sleeper for the
/// same occupant. Keeping the task out of ``CogArenaStorage`` prevents lifetime
/// policy from adding a reference-valued column to hot graph walks.
internal struct CogArenaLifetimeEntry {
  /// Monotonic token advanced before cancellation or replacement.
  var generation: UInt64 = 0

  /// Generation whose deadline has not yet completed, if any.
  var pendingGeneration: UInt64?

  /// Sole grace sleeper owned by this exact row occupant.
  var task: Task<Void, Never>?
}

/// Context-owned data-oriented graph machinery behind the arena selector.
///
/// Stable public references still name descriptors and keys. This context maps
/// those names to generated slots, while hot propagation and settlement carry
/// only integer rows. Descriptor records own typed columns and one dispatch
/// function each; state rows own no classes or closures.
@MainActor
#if !COG_ARENA_COMPACT
@usableFromInline
#endif
internal final class CogArenaCore {
  // Written out, and `nonisolated`, per the rule at the top of
  // `CogDescriptor.swift`. A synthesized `deinit` on a main-actor-isolated
  // class is main-actor-isolated too, so every deallocation asks the
  // concurrency runtime which executor it is on (`M9-13`).
  nonisolated deinit {}

  /// Scalar state rows shared by every descriptor column.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  let arena: CogArenaStorage

  /// Shared linked-edge pool for dependency and subscriber topology.
  let edges: CogLinkedEdgePool

  /// Reused iterative push engine over `edges`.
  let propagation: CogArenaDirtyPropagation

  /// Latest graph revision assigned by the enclosing context turn.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  internal private(set) var revision: UInt32 = 0

  /// Process-unique identity of this graph, issued once at construction.
  ///
  /// Tests, previews, and apps share descriptors but own separate contexts. Any
  /// graph data cached on a descriptor must identify the context that wrote it.
  /// Object identity cannot: a deallocated context's address is reusable, and
  /// a memo compared against a recycled address would silently read another
  /// context's state. A strictly increasing counter is never reused, so a
  /// stale memo simply fails to match.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  let contextIdentity: UInt64

  /// Source of the identities above, advanced once per arena graph.
  ///
  /// MainActor-isolated with the rest of the core, so the increment needs no
  /// atomic. `0` is reserved as the "no memo" sentinel a descriptor starts at.
  private static var nextContextIdentity: UInt64 = 1

  /// Stable descriptor-and-key names resolved to exact slot lifetimes.
  var slots: [CogStateIdentity: CogArenaSlot] = [:]

  /// Strong registry retaining each descriptor record exactly once.
  #if !COG_ARENA_COMPACT
  @usableFromInline
  #endif
  var recordsByIdentity: [ObjectIdentifier: CogArenaDescriptorRecord] = [:]

  /// Integer-indexed unretained view of `recordsByIdentity` for graph walks.
  // Unchecked for the reason `CogArenaStorage` records; every element is trivial.
  @exclusivity(unchecked)
  var records: ContiguousArray<Unmanaged<CogArenaDescriptorRecord>> = []

  /// Reused enter/exit storage for iterative warm settlement.
  // Unchecked for the reason `CogArenaStorage` records; every element is trivial.
  @exclusivity(unchecked)
  var pullFrames: ContiguousArray<CogArenaPullFrame> = []

  /// Reused roots copied from one reaction terminal before its dependencies settle.
  ///
  /// Pulling a producer may recapture edges elsewhere in the shared pool. The
  /// snapshot keeps reaction traversal independent of those mutations without
  /// allocating again after reaching its high-water mark.
  var reactionPullRoots: ContiguousArray<CogArenaSlot> = []

  /// Nested selector scopes, outermost first.
  // Unchecked for the reason `CogArenaStorage` records; every element is trivial.
  @exclusivity(unchecked)
  var captures: ContiguousArray<CogArenaDependencyCapture> = []

  /// UI-read roots in boundary creation order.
  ///
  /// Interior and unread rows never enter this table. Entries are permanent in
  /// v1, making the boundary itself the durable UI lease while the row's scalar
  /// `boundary` column keeps hot storage to one optional index.
  var observationEntries: ContiguousArray<CogArenaObservationEntry> = []

  /// Grace metadata indexed by scalar row for installed value states.
  ///
  /// Reaction-only rows need no entry. The array grows lazily when a value row
  /// is installed and entries reset before a released index changes identity.
  var lifetimeEntries: ContiguousArray<CogArenaLifetimeEntry> = []

  #if DEBUG
  /// Fixed-capacity integer history owned by the arena context.
  ///
  /// This property and every use compile out of release. Arena state events
  /// enter it by descriptor index; labels resolve only through `historySnapshot`.
  var historyLog = CogArenaHistoryLog()
  #endif

  /// Automatic rows whose settlement has entered but not completed, outermost first.
  ///
  /// This stays separate from `pullFrames`: an exit frame is popped before its
  /// selector and equality run, while the row must remain visibly computing
  /// until both have completed.
  // Unchecked for the reason `CogArenaStorage` records; every element is trivial.
  @exclusivity(unchecked)
  var computingPath: ContiguousArray<Int32> = []

  /// Whether traversal, selector capture, and post-selector publication are idle.
  ///
  /// Graph-owned system turns use this complete barrier rather than looking at
  /// frames alone, because a nested cold pull can empty its own frame suffix
  /// while an enclosing selector remains active.
  var isSettlementIdle: Bool {
    pullFrames.isEmpty && captures.isEmpty && computingPath.isEmpty
  }

  /// Rendered name of the innermost automatic row still computing.
  ///
  /// The application turn guard reads this before opening a turn, covering
  /// both selector execution and custom equality.
  var innermostComputingName: String? {
    guard let rawRow = computingPath.last else { return nil }
    return cycleStep(forRow: liveRow(rawRow)).name
  }

  /// The innermost active row names used by the cold-nesting diagnostic.
  func innermostComputingNames(_ count: Int) -> [String] {
    computingPath.suffix(count).map { cycleStep(forRow: liveRow($0)).name }
  }

  /// Creates one empty arena graph and binds its linked-edge propagator.
  init() {
    let arena = CogArenaStorage()
    let edges = CogLinkedEdgePool()
    self.arena = arena
    self.edges = edges
    self.propagation = CogArenaDirtyPropagation(arena: arena, edges: edges)

    guard Self.nextContextIdentity < UInt64.max else {
      fatalError("Cog exhausted its UInt64 arena context identity space.")
    }
    self.contextIdentity = Self.nextContextIdentity
    Self.nextContextIdentity += 1
  }

  /// Advances the compact arena revision once for an enclosing context turn.
  func advanceRevision() {
    guard revision < UInt32.max else {
      fatalError("Cog exhausted its UInt32 arena revision space.")
    }
    revision += 1
  }
}
