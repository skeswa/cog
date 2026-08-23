// scenario: ACTOR-02
//
// Cog's synchronous graph API is MainActor-confined. The valid call proves the
// imported read surface resolves on that executor; the same direct call from a
// different actor must be rejected until its caller explicitly hops.

import Cog

enum OffActorGraphAccessRejected {
  @MainActor
  static func readsOnGraphExecutor(cogs: Cogs, source: Cog<Int>.Manual) -> Int {
    cogs.peek(source)
  }

  actor OtherExecutor {
    func readsWithoutHop(cogs: Cogs, source: Cog<Int>.Manual) -> Int {
      // expect-error: call to main actor-isolated instance method 'peek'
      cogs.peek(source)
    }
  }
}
