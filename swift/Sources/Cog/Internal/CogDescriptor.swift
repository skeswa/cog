// Module-wide rule: every generic class in `Cog` writes its `deinit`
// explicitly, and writes it `nonisolated`.
//
// The package compiles with `.defaultIsolation(MainActor.self)`, which makes a
// class's *synthesized* `deinit` main-actor-isolated. On the pinned toolchain
// (Apple Swift 6.3, swiftlang-6.3.0.123.5) an isolated synthesized `deinit` on
// a **generic** class crashes the optimizer: `swift build -c release` dies with
// SIGSEGV in the `EarlyPerfInliner` SIL pass, which takes down
// `mise run test:release` and every release build a consumer would make.
// Debug builds are unaffected, so the matrix alone would not catch it. Writing
// the `deinit` explicitly avoids the crash.
//
// Spelling that explicit `deinit` `nonisolated` is also right on its own terms:
// these deinits only release their own stored properties, so there is nothing
// to hop to the main actor for. None of these classes is `Sendable`, so an
// instance never leaves the domain that owns it and its last release is on the
// main actor regardless.
//
// This applies to the generic classes M1 adds next — states, boxes, async
// state — not only to descriptors. Delete the lines together once the toolchain
// is fixed, and prove it with a release build.

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
