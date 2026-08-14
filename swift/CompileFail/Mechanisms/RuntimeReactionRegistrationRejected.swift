// scenario: MECH-14
//
// Reactions have one door: a mechanism's controller. The runtime deliberately
// has no reaction, watch, or effect-group API, so late registration outside a
// bootstrap-listed mechanism never compiles. The registrar-shaped members
// below are exactly the spellings the pre-mechanism design offered.

import Cog

enum RuntimeReactionRegistrationRejected {
  static func registersDirectlyOnTheRuntime(cogs: Cogs, source: ManualCog<Int>) {
    // expect-error: value of type 'Cogs' has no member 'run'
    cogs.run { c in
      _ = c[source]
    }
  }

  static func watchesDirectlyOnTheRuntime(cogs: Cogs, source: ManualCog<Int>) {
    // expect-error: value of type 'Cogs' has no member 'watch'
    cogs.watch(source, initial: CogWatchStart.skip) { _, _ in }
  }
}
