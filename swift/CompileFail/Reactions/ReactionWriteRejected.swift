// scenario: REACT-14
//
// A reaction receives a read controller, not a writer. It can read a source to
// establish a dependency, but its subscript is read-only. A reaction that
// needs to change state instead calls an op on its mechanism's controller, so
// the write follows `turn`'s normal turn rules.

import Cog

enum ReactionWriteRejected {
  static func writesThroughReactionController(m: MechanismController, source: Cog<Int>.Manual) {
    m.run { c in
      _ = c[source]

      // expect-error: cannot assign through subscript: subscript is get-only
      c[source] = 1
    }
  }
}
