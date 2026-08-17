#if COG_CORE_ARENA
/// Temporary class-state terminal for a reaction that reads an arena row.
///
/// Reactions migrate into indexed topology in M6-10ca. Until then, this state
/// lets their existing scheduler subscribe to an arena value without running a
/// second copy of its selector. Before reactions flush, the context marks a
/// bridge CHECK when its row has work; reaction settlement pulls that row and
/// advances the bridge's class-core version only if the arena value changed.
@MainActor
internal final class CogArenaReactionBridge: CogState {
  /// Human-readable declaration label used by diagnostics and lease bookkeeping.
  let label: CogLabel

  /// Whether the arena row changed this revision or still needs settlement.
  private let arenaNeedsCheck: @MainActor (Cogs) -> Bool

  /// Pulls the arena row current and reports whether its value changed this revision.
  private let settleArena: @MainActor (Cogs) -> Bool

  /// CHECK while a corresponding arena row may affect this terminal bridge.
  var settleState: CogSettleState

  /// Last context revision in which arena settlement changed the bridged value.
  var changedAt: CogVersion

  /// Last context revision through which the bridge was proved current.
  var checkedAt: CogVersion

  /// Class-backed reactions subscribed to this transitional terminal.
  var subscribers: [CogSubscriberEdge]

  /// Creates one already-current bridge after its initial arena read.
  init(
    label: CogLabel,
    checkedAt: CogVersion,
    arenaNeedsCheck: @escaping @MainActor (Cogs) -> Bool,
    settleArena: @escaping @MainActor (Cogs) -> Bool
  ) {
    self.label = label
    self.arenaNeedsCheck = arenaNeedsCheck
    self.settleArena = settleArena
    self.settleState = .clean
    self.changedAt = .initial
    self.checkedAt = checkedAt
    self.subscribers = []
  }

  /// Marks this bridge and its reactions CHECK when its arena row has work.
  ///
  /// Subscribers receive CHECK rather than DIRTY because pulling the arena row
  /// may backdate an equal recomputation. That equality must stop the wave
  /// before the reaction body runs.
  func prepareForReactionFlush(in cogs: Cogs) {
    guard arenaNeedsCheck(cogs) else { return }
    markForCheck()
    for edge in subscribers {
      edge.state?.markForCheck()
    }
  }

  /// Pulls the arena row and mirrors only its version result into this terminal.
  func settle(in cogs: Cogs) {
    guard settleState != .clean else { return }
    if settleArena(cogs) {
      markChanged(at: cogs.revision)
    } else {
      markChecked(at: cogs.revision)
    }
  }
}

extension Cogs {
  /// Returns the reaction terminal for one arena source after its initial read.
  func arenaReactionBridge<Value>(
    for valueReference: ManualCog<Value>
  ) -> CogArenaReactionBridge {
    let identity = CogStateIdentity(
      descriptor: valueReference.descriptor.identity,
      key: valueReference.key
    )
    if let bridge = arenaReactionBridges[identity] { return bridge }

    let bridge = CogArenaReactionBridge(
      label: valueReference.descriptor.label,
      checkedAt: revision,
      arenaNeedsCheck: { cogs in
        cogs.arenaCore.reactionBridgeNeedsCheck(valueReference)
      },
      settleArena: { cogs in
        cogs.arenaCore.settleReactionBridge(valueReference)
      }
    )
    arenaReactionBridges[identity] = bridge
    return bridge
  }

  /// Returns the reaction terminal for one arena derived row after its initial read.
  func arenaReactionBridge<Value>(
    for valueReference: Cog<Value>
  ) -> CogArenaReactionBridge {
    let identity = CogStateIdentity(
      descriptor: valueReference.descriptor.identity,
      key: valueReference.key
    )
    if let bridge = arenaReactionBridges[identity] { return bridge }

    let bridge = CogArenaReactionBridge(
      label: valueReference.descriptor.label,
      checkedAt: revision,
      arenaNeedsCheck: { cogs in
        cogs.arenaCore.reactionBridgeNeedsCheck(valueReference)
      },
      settleArena: { cogs in
        cogs.arenaCore.settleReactionBridge(valueReference, in: cogs)
      }
    )
    arenaReactionBridges[identity] = bridge
    return bridge
  }

  /// Propagates arena uncertainty into existing class-backed reaction terminals.
  func prepareArenaReactionBridgesForFlush() {
    for bridge in arenaReactionBridges.values {
      bridge.prepareForReactionFlush(in: self)
    }
  }
}
#endif
