import Cog
import CogTesting
import Testing

@MainActor
@Test func `ACTOR-01 derived selectors execute on the MainActor`() {
  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(21)
  var selectorRuns = 0
  let doubled = Cog<Int> { c in
    MainActor.preconditionIsolated("Cog selector")
    selectorRuns += 1
    return c.get(source) * 2
  }

  #expect(cogs.read(doubled) == 42)
  #expect(selectorRuns == 1)
}

@MainActor
@Test func `ACTOR-01 commit bodies execute on the MainActor`() {
  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(0)
  var bodyRuns = 0

  cogs.commit { w in
    MainActor.preconditionIsolated("Cog commit body")
    bodyRuns += 1
    w[source] = 1
  }

  #expect(bodyRuns == 1)
  #expect(cogs.read(source) == 1)
}

@MainActor
@Test func `ACTOR-01 reactions execute on the MainActor`() {
  let cogs = Cogtext.forTesting()
  let source = ManualCog<Int>(0)
  var seen: [Int] = []

  let token = cogs.run { c in
    MainActor.preconditionIsolated("Cog reaction")
    seen.append(c.get(source))
  }

  #expect(seen == [0])

  cogs.commit { w in w[source] = 1 }

  #expect(seen == [0, 1])
  _ = token
}
