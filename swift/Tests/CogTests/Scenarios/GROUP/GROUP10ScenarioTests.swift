import Cog
import CogTesting
import Testing

@MainActor
@Test func `GROUP-10 adding reactions cannot reopen a cancelled group`() {
  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(0)
  let group = EffectGroup()
  let copy = group

  group.cancel()

  var firstRuns = 0
  var firstToken: ReactionToken? = cogs.run { reader in
    _ = reader.get(source)
    firstRuns += 1
  }
  weak let releasedToken = firstToken
  copy.add(firstToken!)
  firstToken = nil

  #expect(releasedToken == nil)
  cogs.commit { writer in writer[source] = 1 }
  #expect(firstRuns == 1)

  var secondRuns = 0
  let anotherCopy = copy
  anotherCopy.add(
    cogs.run { reader in
      _ = reader.get(source)
      secondRuns += 1
    })
  cogs.commit { writer in writer[source] = 2 }
  #expect(secondRuns == 1)

  var cancelledRuns = 0
  let cancelledToken = cogs.run { reader in
    _ = reader.get(source)
    cancelledRuns += 1
  }
  cancelledToken.cancel()
  group.add(cancelledToken)
  cogs.commit { writer in writer[source] = 3 }
  #expect(cancelledRuns == 1)
}
