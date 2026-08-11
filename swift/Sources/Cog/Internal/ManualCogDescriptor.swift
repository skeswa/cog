/// The descriptor behind a manual source declaration.
///
/// One descriptor stands behind one ``ManualCog`` declaration. It is generic
/// over the value but not over a key: the correctness build spells keys as an
/// inline `AnyHashable?` on the ref (perf §4), so a keyless declaration and a
/// keyed box can share this one descriptor kind.
internal final class ManualCogDescriptor<Value>: CogDescriptor {
  let label: CogLabel

  /// The value a node for this declaration holds before anything writes to it.
  ///
  /// The starting value lives on the descriptor because the declaration is
  /// what knows it. Nodes appear lazily per descriptor and key, so whichever
  /// node appears first — in the app context, or in a test or preview
  /// runtime — has to start somewhere, and it cannot ask a turn that never
  /// happened.
  let startingValue: Value

  init(startingValue: Value, label: CogLabel) {
    self.label = label
    self.startingValue = startingValue
  }

  // Written out, and `nonisolated`, per the rule at the top of
  // `CogDescriptor.swift`. Removing it crashes the release build.
  nonisolated deinit {}
}
