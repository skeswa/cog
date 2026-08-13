// scenario: SEED-06
//
// `seed` accepts a manual source because test setup may replace owned state. A
// derived Cog is computed state, so passing one to the same public API must
// fail in the type checker rather than becoming a runtime convention.
//
// The valid first call proves this fixture resolved the real debug `seed`
// surface before the second call tests its value-reference restriction. The context and
// value references are parameters so no bootstrap or construction rule is involved.
//
// The harness imports CogTesting's debug build, where `seed` exists. This
// fixture is deliberately not wrapped in `#if DEBUG`: its separate frontend is
// not passed that define, and gating it would compile the proof away.

import Cog
import CogTesting

enum DerivedSeedRejected {
  static func seedsOnlyManualSources(
    cogs: Cogs,
    source: ManualCog<Int>,
    derived: Cog<Int>
  ) {
    cogs.seed(source, to: 1)

    // expect-error: cannot convert value of type 'Cog<Int>' to expected argument type 'ManualCog<Int>'
    cogs.seed(derived, to: 2)
  }
}
