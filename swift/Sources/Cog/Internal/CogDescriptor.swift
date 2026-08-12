// Every generic class in Cog writes an explicit `nonisolated deinit`.
//
// The package compiles with `.defaultIsolation(MainActor.self)`, which makes a
// class's *synthesized* `deinit` main-actor-isolated. On the pinned toolchain
// (Apple Swift 6.3, swiftlang-6.3.0.123.5) an isolated synthesized `deinit` on
// a generic class crashes the release optimizer in `EarlyPerfInliner`. Debug
// builds are unaffected, so the test matrix does not catch it.
//
// These deinitializers only release their stored properties and must not touch
// MainActor-isolated graph state. Remove them together only after the
// toolchain is fixed and a release build proves the workaround unnecessary.

/// The shape every declaration's descriptor shares.
///
/// A descriptor names state; it does not hold it. The app's one `Cogtext`
/// stores a state per descriptor and key, created lazily, and a test or preview
/// runtime has its own isolated context (§2.3). That split is what makes a
/// top-level `let` a light declaration rather than a live global value.
///
/// Descriptors are internal `final` classes and **identity is the object**:
/// `ObjectIdentifier` gives a distinct, stable name for every declaration
/// without a registry, a counter, or any coordination between files. Two
/// declarations with identical labels, starting values, and types are still two
/// different cogs. Users never see the object identifier — they see
/// ``CogLabel``.
///
/// The protocol carries only what code that does not know a descriptor's value
/// type still needs: its identity and its label. State storage keys on the
/// former; cycle diagnostics and debug history print the latter.
@MainActor
internal protocol CogDescriptor: AnyObject {
  /// What Cog calls this declaration when it prints about it.
  var label: CogLabel { get }
}

extension CogDescriptor {
  /// Stable process identity for this declaration.
  ///
  /// `ObjectIdentifier` is only guaranteed unique among live objects, which is
  /// exactly enough here: a descriptor is owned by the declaration that created
  /// it — normally a top-level `let` — so it outlives every state, edge, and
  /// history entry that refers to it.
  var identity: ObjectIdentifier {
    ObjectIdentifier(self)
  }
}
