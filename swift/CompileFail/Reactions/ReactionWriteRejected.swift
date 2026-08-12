// scenario: REACT-14
//
// A reaction receives a read controller, not a writer. It can read a source to
// establish a dependency, but its subscript is read-only. A reaction that
// needs to change state instead captures its context and calls an op, so the
// write follows `commit`'s normal turn rules.

import Cog

enum ReactionWriteRejected {
  static func writesThroughReactionController(cogs: Cogtext, source: ManualCog<Int>) {
    cogs.run { c in
      _ = c[source]

      // expect-error: cannot assign through subscript: subscript is get-only
      c[source] = 1
    }
  }
}
