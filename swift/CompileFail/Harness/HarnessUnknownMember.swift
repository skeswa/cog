// scenario: HARNESS-02
//
// Sentinel. Proves the batched pass really resolves the built `Cog` module:
// the import succeeds and a type only that module defines is in scope, while
// the member asked of it does not exist. Point `-I` at nothing and both halves
// break loudly — the import fails with an uncovered `no such module`, and
// `Cogtext` becomes an uncovered `cannot find ... in scope`.
//
// It used to ask the *module* for a missing member, as `Cog.NoSuchSymbol`.
// `M1-05a` added the public derived-cog ref `Cog<Value>`, and a type shadows
// its own module in qualified lookup, so that spelling now asks the type and
// reports a generic-inference error instead. Naming a distinct type keeps this
// fixture proving module resolution rather than name shadowing.

import Cog

enum HarnessUnknownMember {
  static func referencesAMissingModuleMember() {
    // expect-error: type 'Cogtext' has no member 'NoSuchSymbol'
    _ = Cogtext.NoSuchSymbol.self
  }
}
