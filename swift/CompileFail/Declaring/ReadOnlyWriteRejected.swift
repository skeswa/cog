// scenario: DECL-06
//
// A read-only value reference cannot be written, and "cannot" means the write does not
// compile — not that it traps, warns, or is merely discouraged by a comment.
//
// This is the enforcement half of write ownership. A file keeps its
// sources `fileprivate` so only it can name them, and publishes `.readOnly`
// projections for everyone else. That buys nothing unless the projection is
// genuinely inert: ``Writer``'s subscript takes a `ManualCog`, and a
// `CogProjection` is a different type, so every spelling of a write below is a
// type error at the argument, before any turn exists to reject it.
//
// The fixture takes its context and its value reference as parameters. It never builds
// either, because it does not need to: the rejection happens in the type
// checker, and a fixture that constructed a context would be asserting
// something about bootstrap instead.

import Cog

enum ReadOnlyWriteRejected {
  /// The plain case: stage a value through a published read-only value reference.
  static func stagesThroughAReadOnlyValueReference(
    cogs: Cogtext, currentZipCode: CogProjection<Int>
  ) {
    cogs.commit { w in
      // expect-error: cannot convert value of type 'CogProjection<Int>' to expected argument type 'ManualCog<Int>'
      w[currentZipCode] = 90210
    }
  }

  /// Read-modify-write, which the writer's subscript supports for a real
  /// source (`w[count] += 1`) and must not offer here.
  static func mutatesThroughAReadOnlyValueReference(cogs: Cogtext, retryLimit: CogProjection<Int>) {
    cogs.commit { w in
      // expect-error: cannot convert value of type 'CogProjection<Int>' to expected argument type 'ManualCog<Int>'
      w[retryLimit] += 1
    }
  }

  /// A key does not launder a projection. `readOnlyBox[key]` builds a
  /// read-only value reference like every other, so the keyed write is the same type
  /// error as the keyless one.
  static func stagesThroughAReadOnlyBoxKey(
    cogs: Cogtext,
    weatherReport: CogBoxProjection<Int, String>
  ) {
    cogs.commit { w in
      // expect-error: cannot convert value of type 'CogProjection<Int>' to expected argument type 'ManualCog<Int>'
      w[weatherReport["90210"]] = 72
    }
  }
}
