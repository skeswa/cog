// scenario: HARNESS-03
//
// Sentinel. The M0 stub library exports no public API: `CogScaffolding` is
// internal to the `Cog` module, so a consumer cannot see it. When M1 lands the
// real surface this fixture stays honest — scaffolding is never API.

import Cog

enum HarnessStubHasNoAPI {
  static func referencesInternalScaffolding() {
    // expect-error: cannot find 'CogScaffolding' in scope
    _ = CogScaffolding.marker
  }
}
