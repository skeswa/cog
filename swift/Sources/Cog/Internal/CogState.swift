/// One live piece of state inside one ``Cogtext``.
///
/// A descriptor and key name state; a value reference carries that name, and a
/// `CogState` is the live state stored in one context (§2.2, §2.3). The same
/// declaration therefore has one state in the app context, a separate state in
/// each test or preview runtime, and no state in a context that has never been
/// asked for it.
///
/// The protocol carries only what code holding state of unknown value type
/// still needs: its label for diagnostics, and the state and versions the
/// settle walk updates. Keeping it this narrow is deliberate: `Cogtext`'s
/// storage is heterogeneous, so every capability that crosses the existential
/// has to be spelled out here rather than recovered by casting to a concrete
/// state kind.
@MainActor
internal protocol CogState: AnyObject {
  /// What Cog calls the declaration this state belongs to.
  var label: CogLabel { get }

  /// Whether the state is current, may need checking, or must recompute.
  var settleState: CogSettleState { get set }

  /// The last graph revision in which this state's value really changed.
  var changedAt: CogVersion { get set }

  /// The last graph revision through which this state was proved current.
  var checkedAt: CogVersion { get set }

  /// Consumers whose last run read this state.
  ///
  /// Reverse edges make source writes a cheap push of flags rather than a scan
  /// of the context. The simple core stores class references; M6 replaces the
  /// physical layout behind unchanged behavior.
  var subscribers: [CogSubscriberEdge] { get set }
}

/// What a ``Cogtext`` files a state under: a declaration plus a key.
///
/// Identity is descriptor plus key (§3.1). The descriptor half is its
/// `ObjectIdentifier`, which is a distinct, stable name for every declaration
/// without a registry or a counter (§2.3). The key half is `nil` for a keyless
/// declaration and the box key for a keyed one, so a keyless cog is simply the
/// single-state case of the same storage rather than a second mechanism.
///
/// This is `nonisolated` because it is inert data. `Hashable`'s requirements
/// are nonisolated, so a main-actor-isolated identity could not satisfy them,
/// and a dictionary key that needed an actor to compare would be useless.
/// Building one still happens on the MainActor, since reading a descriptor's
/// identity does.
///
/// Inline `AnyHashable?` is the correctness build's key representation, the
/// same choice ``ManualCog`` makes for the value reference, and it stays open for
/// benchmarks to revisit (perf §4, §9).
internal nonisolated struct CogStateIdentity: Hashable {
  /// The declaration, by process identity.
  let descriptor: ObjectIdentifier

  /// Which state of `descriptor` this names, or `nil` for a keyless
  /// declaration.
  let key: AnyHashable?
}
