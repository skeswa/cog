// scenario: ASYNC-33
//
// The `status` lens exists only for async references, and "only" means a
// synchronous cog cannot be asked for request status at all — the request
// does not compile, rather than answering with fabricated always-success data.
//
// This is the type-system half of the value-first read model (§5.1). Manual
// and automatic cogs are always settled values; uncertainty is an async-only
// concept, and it lives in `CogStatus` behind the lens. Every lens subscript
// takes an `AsyncCog`, so a manual or automatic reference is a type error at
// the argument, on every capability that carries the lens.
//
// The fixture takes its context and references as parameters. It never builds
// them, because the rejection happens in the type checker.

import Cog

enum StatusRefusesSyncCogs {
  /// The UI-boundary lens rejects a manual source.
  static func asksTheUILensForAManualCog(
    cogs: Cogs, currentZipCode: ManualCog<Int>
  ) {
    // expect-error: cannot convert value of type 'ManualCog<Int>' to expected argument type 'AsyncCog<Value>'
    // expect-error: generic parameter 'Value' could not be inferred
    _ = cogs.status[currentZipCode]
  }

  /// The UI-boundary lens rejects an automatic cog.
  static func asksTheUILensForAAutomaticCog(cogs: Cogs, isNice: Cog<Bool>) {
    // expect-error: cannot convert value of type 'Cog<Bool>' to expected argument type 'AsyncCog<Value>'
    // expect-error: generic parameter 'Value' could not be inferred
    _ = cogs.status[isNice]
  }

  /// The selector-side lens rejects an automatic cog the same way.
  static func asksASelectorLensForAAutomaticCog(isNice: Cog<Bool>) -> Cog<Bool> {
    Cog<Bool> { c in
      // expect-error: cannot convert value of type 'Cog<Bool>' to expected argument type 'AsyncCog<Read>'
      // expect-error: generic parameter 'Read' could not be inferred
      _ = c.status[isNice]
      return false
    }
  }
}
