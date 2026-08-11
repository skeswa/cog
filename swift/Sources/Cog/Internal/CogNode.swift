/// One live piece of state inside one ``Cogtext``.
///
/// A descriptor names state and a ref points at it; a *node* is the state
/// itself (§2.2, §2.3). Nodes exist per context, so the same declaration has
/// one node in the app context and a separate node in each test or preview
/// runtime, and no node at all in a context that has never been asked for it.
///
/// The protocol carries only what code holding a node of unknown value type
/// still needs. Today that is the label, which is what a cycle diagnostic and
/// the debug history print (§2.4, §6.5); the settle state, versions, and edge
/// storage join it as the later M1 tasks land. Keeping it this narrow is
/// deliberate: `Cogtext`'s storage is heterogeneous, so every capability that
/// crosses the existential has to be spelled out here rather than recovered by
/// casting to a concrete node kind.
@MainActor
internal protocol CogNode: AnyObject {
  /// What Cog calls the declaration this node belongs to.
  var label: CogLabel { get }
}

/// What a ``Cogtext`` files a node under: a declaration plus a key.
///
/// Identity is descriptor plus key (§3.1). The descriptor half is its
/// `ObjectIdentifier`, which is a distinct, stable name for every declaration
/// without a registry or a counter (§2.3). The key half is `nil` for a keyless
/// declaration and the box key for a keyed one, so a keyless cog is simply the
/// single-node case of the same storage rather than a second mechanism.
///
/// This is `nonisolated` because it is inert data. `Hashable`'s requirements
/// are nonisolated, so a main-actor-isolated identity could not satisfy them,
/// and a dictionary key that needed an actor to compare would be useless.
/// Building one still happens on the MainActor, since reading a descriptor's
/// identity does.
///
/// Inline `AnyHashable?` is the correctness build's key representation, the
/// same choice ``ManualCog`` makes for the ref, and it stays open for
/// benchmarks to revisit (perf §4, §9).
internal nonisolated struct CogNodeIdentity: Hashable {
  /// The declaration, by process identity.
  let descriptor: ObjectIdentifier

  /// Which node of `descriptor` this names, or `nil` for a keyless
  /// declaration.
  let key: AnyHashable?
}
