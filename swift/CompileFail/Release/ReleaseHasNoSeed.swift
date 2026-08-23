// scenario: SEED-05
// configuration: release
//
// `CogTesting.seed` exists only in debug builds; a release build has no way to
// seed. The SEED suite cannot prove this from inside the test target — its
// tests are themselves `#if DEBUG`-gated, so removing the library's gate would
// leave every leg green. Type-checking this call against the release-built
// modules is the direct proof: the member must not exist there at all.

import Cog
import CogTesting

enum ReleaseHasNoSeed {
  static func cannotSeed(cogs: Cogs, source: Cog<Int>.Manual) {
    // expect-error: value of type 'Cogs' has no member 'seed'
    cogs.seed(source, to: 1)
  }
}
