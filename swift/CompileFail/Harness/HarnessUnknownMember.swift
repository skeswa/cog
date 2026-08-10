// scenario: HARNESS-02
//
// Sentinel. Proves the batched pass really resolves the built `Cog` module:
// the import succeeds (an unresolved import would surface as an uncovered
// `no such module` error) while the member does not exist.

import Cog

enum HarnessUnknownMember {
  static func referencesAMissingModuleMember() {
    // expect-error: module 'Cog' has no member named 'NoSuchSymbol'
    _ = Cog.NoSuchSymbol.self
  }
}
