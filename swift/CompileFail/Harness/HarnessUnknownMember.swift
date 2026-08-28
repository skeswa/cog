// scenario: HARNESS-02
//
// Sentinel. Proves the batched pass really resolves the built `Cog` module:
// the import succeeds and a type only that module defines is in scope, while
// the member asked of it does not exist. Point `-I` at nothing and both halves
// break loudly: the import fails with an uncovered `no such module`, and
// `Cogs` becomes an uncovered `cannot find ... in scope`.

import Cog

enum HarnessUnknownMember {
  static func referencesAMissingModuleMember() {
    // expect-error: type 'Cogs' has no member 'NoSuchSymbol'
    _ = Cogs.NoSuchSymbol.self
  }
}
