// scenario: ASYNC-33
//
// The `phase` lens exists only for async references, and "only" means a
// synchronous cog cannot be asked for a phase at all — the request does not
// compile, rather than answering with a fabricated always-success phase.
//
// This is the type-system half of the value-first read model (§5.1). Manual
// and derived cogs are always settled values; uncertainty is an async-only
// concept, and it lives in `CogPhase` behind the lens. Every lens subscript
// takes an `AsyncCog`, so a manual or derived reference is a type error at
// the argument, on every capability that carries the lens.
//
// The fixture takes its context and references as parameters. It never builds
// them, because the rejection happens in the type checker.

import Cog

enum PhaseRefusesSyncCogs {
  /// The UI-boundary lens rejects a manual source.
  static func asksTheUILensForAManualCog(
    cogs: Cogtext, currentZipCode: ManualCog<Int>
  ) {
    // expect-error: cannot convert value of type 'ManualCog<Int>' to expected argument type 'AsyncCog<Value>'
    // expect-error: generic parameter 'Value' could not be inferred
    _ = cogs.phase[currentZipCode]
  }

  /// The UI-boundary lens rejects a derived cog.
  static func asksTheUILensForADerivedCog(cogs: Cogtext, isNice: Cog<Bool>) {
    // expect-error: cannot convert value of type 'Cog<Bool>' to expected argument type 'AsyncCog<Value>'
    // expect-error: generic parameter 'Value' could not be inferred
    _ = cogs.phase[isNice]
  }

  /// The selector-side lens rejects a derived cog the same way.
  static func asksASelectorLensForADerivedCog(isNice: Cog<Bool>) -> Cog<Bool> {
    Cog<Bool> { c in
      // expect-error: cannot convert value of type 'Cog<Bool>' to expected argument type 'AsyncCog<Read>'
      // expect-error: generic parameter 'Read' could not be inferred
      _ = c.phase[isNice]
      return false
    }
  }
}
