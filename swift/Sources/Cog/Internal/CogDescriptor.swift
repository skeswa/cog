// Every class in Cog writes an explicit `deinit`, and it is `nonisolated`
// unless deallocation genuinely has to reach the graph.
//
// The package compiles with `.defaultIsolation(MainActor.self)`, which makes a
// class's *synthesized* `deinit` main-actor-isolated. That is wrong twice over.
//
// For a generic class it is a build problem: on the pinned toolchain (Apple
// Swift 6.3, swiftlang-6.3.0.123.5) an isolated synthesized `deinit` on a
// generic class crashes the release optimizer in `EarlyPerfInliner`. Debug
// builds are unaffected, so the test matrix does not catch it.
//
// For every class it is a cost. An isolated `deinit` compiles to
// `swift_task_deinitOnExecutor`, so each deallocation asks the concurrency
// runtime which executor it is on and can hop if the answer is wrong. `M9-01`
// measured that traffic at about an eighth of a steady turn; `M9-13` annotated
// the classes that were still paying it. A controlled two-file comparison
// confirms the mechanism: a bare main-actor class references
// `swift_task_deinitOnExecutor`, `swift_task_isCurrentExecutor`, and
// `swift_task_reportUnexpectedExecutor`, and the same class with
// `nonisolated deinit {}` references none of them.
//
// These deinitializers only release their stored properties and must not touch
// MainActor-isolated graph state. A class whose cleanup does need the graph
// writes `isolated deinit` instead and must not be generic; `ReactionToken` is
// the worked example. The two spellings solve opposite problems and neither is
// a fix for the other.

/// The shape every declaration's descriptor shares.
///
/// A descriptor names state but does not store it. Each `Cogs` creates its
/// own state for a descriptor and key (§2.3). The descriptor and all mutable
/// state it names are MainActor-confined; copied public value references share
/// this declaration identity rather than copying graph state.
///
/// Descriptor object identity distinguishes declarations without a registry.
/// Two declarations remain distinct even if their labels, types, and starting
/// values match. Diagnostics show their ``CogLabel``.
///
/// Type-erased code needs only the descriptor's identity and label.
@MainActor
#if !COG_ARENA_COMPACT
@usableFromInline
#endif
internal protocol CogDescriptor: AnyObject {
  /// What Cog calls this declaration when it prints about it.
  var label: CogLabel { get }
}

extension CogDescriptor {
  /// Stable process identity for this declaration.
  ///
  /// Public references and every live state retain their descriptor, so this
  /// identity cannot be reused while either can still address the declaration.
  /// Debug history stores rendered labels and keys rather than retaining a
  /// descriptor solely for diagnostics.
  #if !COG_ARENA_COMPACT
  @inlinable
  #endif
  var identity: ObjectIdentifier {
    ObjectIdentifier(self)
  }
}
