/// One live piece of state inside one ``Cogtext``.
///
/// A descriptor and key name state. Each context creates its own state on first
/// use (§2.2, §2.3).
///
/// This protocol exposes the fields needed by type-erased storage and
/// settlement.
@MainActor
internal protocol CogState: AnyObject {
  /// What Cog calls the declaration this state belongs to.
  var label: CogLabel { get }

  /// Whether the state is current, may need checking, or must recompute.
  var settleState: CogSettleState { get set }

  /// The last graph revision in which this state's value changed.
  var changedAt: CogVersion { get set }

  /// The last graph revision through which this state was proved current.
  var checkedAt: CogVersion { get set }

  /// Consumers whose last run read this state.
  ///
  /// Reverse edges let writes invalidate consumers without scanning the graph.
  /// M6 replaces the class-reference layout.
  var subscribers: [CogSubscriberEdge] { get set }
}

/// What a ``Cogtext`` files a state under: a declaration plus a key.
///
/// Identity is the descriptor's `ObjectIdentifier` plus an optional key (§2.3,
/// §3.1).
///
/// The type is `nonisolated` because `Hashable` requires nonisolated equality.
/// It is still built on the MainActor.
///
/// The correctness core uses `AnyHashable?`; benchmarks may change the layout
/// (perf §4, §9).
internal nonisolated struct CogStateIdentity: Hashable {
  /// The declaration, by process identity.
  let descriptor: ObjectIdentifier

  /// Which state of `descriptor` this names, or `nil` for a keyless
  /// declaration.
  let key: AnyHashable?
}
