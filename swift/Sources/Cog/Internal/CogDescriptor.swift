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
/// A descriptor names state but does not store it. Each `Cogtext` creates its
/// own state for a descriptor and key (§2.3).
///
/// Descriptor object identity distinguishes declarations without a registry.
/// Two declarations remain distinct even if their labels, types, and starting
/// values match. Diagnostics show their ``CogLabel``.
///
/// Type-erased code needs only the descriptor's identity and label.
@MainActor
internal protocol CogDescriptor: AnyObject {
  /// What Cog calls this declaration when it prints about it.
  var label: CogLabel { get }
}

extension CogDescriptor {
  /// Stable process identity for this declaration.
  ///
  /// The declaration owns its descriptor, so the object outlives every state,
  /// edge, and history entry that refers to it.
  var identity: ObjectIdentifier {
    ObjectIdentifier(self)
  }
}
